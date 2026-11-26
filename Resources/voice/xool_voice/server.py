"""The sidecar's loop: JSON lines on stdin and stdout.

The app (VoiceBridge.swift) sends commands, one JSON object per line:
  {"cmd":"listen","mode":"off"|"ptt"|"vad","barge_in":true}
  {"cmd":"ptt","down":true|false}        push-to-talk key pressed / released
  {"cmd":"say","text":"…","first":true}  speak one sentence (queued, in order)
  {"cmd":"bridge","kind":"frage"}        a ready-made bridge phrase, if nothing is being said
  {"cmd":"stop"}                         silence now and forget what is queued
  {"cmd":"transcribe","path":"x.wav"}    test input: a WAV file instead of the microphone
  {"cmd":"quit"}
and gets events back, one per line:
  ready{stt,tts,vad}  loading{what}  status{state}  speech_start  barge_in
  transcript{text,kind}  speaking{on}  idle  bridge{text}  error{text}

stdout carries only these lines; everything else goes to stderr.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
import wave

import numpy as np

from .bruecken import FillerBank, classify, strip_leading_filler
from .text import clean_for_speech, looks_like_hallucination
from .vad import CHUNK_SEC, SAMPLE_RATE, TurnDetector, make_vad


class NullPlayer:
    """Plays nothing, but takes the time the audio would take (tests without speakers)."""

    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self._until = 0.0
        self.last_sound = 0.0
        self.played_seconds = 0.0

    def play(self, audio, on_start=None):
        now = time.monotonic()
        start = max(now, self._until)
        self._until = start + len(audio) / self.sample_rate
        self.played_seconds += len(audio) / self.sample_rate
        if on_start:
            on_start()

    def stop(self):
        self._until = 0.0

    @property
    def busy(self) -> bool:
        return time.monotonic() < self._until


def read_wav16k(path: str) -> np.ndarray:
    """int16 mono 16 kHz from a WAV file (other rates and channels are converted)."""
    from .audio import resample

    with wave.open(path, "rb") as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError("Only 16-bit WAV files are supported.")
    audio = np.frombuffer(raw, dtype=np.int16)
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1).astype(np.int16)
    return resample(audio.astype(np.float32), rate, SAMPLE_RATE).astype(np.int16)


class Server:
    def __init__(self, voice: str | None = None, whisper: str | None = None, speed: float = 1.05,
                 pause: float = 0.6, null_audio: bool = False, name: str = "Xool", language: str = "de"):
        self.language = language
        self.out = sys.stdout
        sys.stdout = sys.stderr  # nothing but events may reach the real stdout
        self.lock_out = threading.Lock()
        self.name, self.speed, self.pause = name, speed, pause
        self.voice_arg, self.whisper_arg, self.null_audio = voice, whisper, null_audio
        self.mode = "off"
        self.barge_in = True
        self.tts = self.player = self.stt = self.fillers = self.vad = None
        self.stt_lock = threading.Lock()
        self.mic = None
        self.mic_thread: threading.Thread | None = None
        self.mic_run = threading.Event()
        self.ptt_down = threading.Event()
        self.ptt_audio: list[np.ndarray] = []
        self.generation = 0  # raised by stop(): older queued sentences are dropped
        self.say_q: queue.Queue = queue.Queue()
        self.bridged = False
        self.speaking = False
        self.quit = threading.Event()
        self.detector = TurnDetector(end_silence=pause)

    # -- events ------------------------------------------------------------------------
    def emit(self, ev: str, **data) -> None:
        with self.lock_out:
            self.out.write(json.dumps({"ev": ev, **data}, ensure_ascii=False) + "\n")
            self.out.flush()

    def log(self, text: str) -> None:
        print(text, file=sys.stderr, flush=True)

    # -- loading -----------------------------------------------------------------------
    def load(self) -> None:
        from .tts import PiperTTS, find_voice

        path = find_voice(self.voice_arg)
        if path is None:
            self.emit("error", text="No voice file found. Run scripts/xool-setup.sh.", fatal=True)
            raise SystemExit(2)
        self.tts = PiperTTS(path, speed=self.speed)
        if self.null_audio:
            self.player = NullPlayer(self.tts.sample_rate)
        else:
            from .audio import Player

            self.player = Player(self.tts.sample_rate)
        self.vad, vad_name = make_vad()
        self.fillers = FillerBank(self.tts)
        self.fillers.prepare(background=True)
        threading.Thread(target=self._say_worker, daemon=True).start()
        threading.Thread(target=self._speaking_monitor, daemon=True).start()
        self.emit("ready", tts=self.tts.name, vad=vad_name, null_audio=self.null_audio)
        threading.Thread(target=self._load_stt, daemon=True).start()

    def _load_stt(self) -> None:
        try:
            self.emit("loading", what="ears")
            from .stt import make_stt, warmup

            with self.stt_lock:
                self.stt = make_stt(self.whisper_arg, self.language)
                warmup(self.stt)
            self.emit("loaded", what="ears", stt=self.stt.name)
        except Exception as e:
            self.emit("error", text=f"Speech recognition didn't load: {e}")

    # -- speaking ----------------------------------------------------------------------
    def say(self, text: str, first: bool = False) -> None:
        if first and self.bridged:
            text = strip_leading_filler(text)
        if first:
            self.bridged = False
        self.say_q.put((self.generation, text))

    def _say_worker(self) -> None:
        while True:
            gen, text = self.say_q.get()
            try:
                text = clean_for_speech(text)
                if gen != self.generation or not text:
                    continue
                audio = self.tts.synth(text)
                if gen != self.generation:
                    continue
                self.player.play(audio)
            except Exception as e:
                self.emit("error", text=f"Speaking failed: {e}")
            finally:
                self.say_q.task_done()

    def _speaking_monitor(self) -> None:
        while not self.quit.is_set():
            now = bool(self.player.busy) or self.say_q.unfinished_tasks > 0
            if now != self.speaking:
                self.speaking = now
                self.emit("speaking", on=now)
                if not now:
                    self.emit("idle")
            time.sleep(0.04)

    def stop(self) -> None:
        self.generation += 1
        self.bridged = False
        self.player.stop()
        while True:
            try:
                self.say_q.get_nowait()
                self.say_q.task_done()
            except queue.Empty:
                break

    def bridge(self, kind: str) -> None:
        if self.speaking or not self.fillers:
            return
        picked = self.fillers.pick(kind)
        if not picked:
            return
        phrase, audio = picked
        breath = self.fillers.maybe_breath() if kind not in ("hallo", "suche") else None
        if breath is not None:
            self.player.play(breath)
        self.player.play(audio)
        self.bridged = True
        self.emit("bridge", text=phrase)

    # -- listening ---------------------------------------------------------------------
    def set_mode(self, mode: str, barge_in: bool = True) -> None:
        self.barge_in = barge_in
        if mode == self.mode:
            return
        self.mode = mode
        self._close_mic()
        if mode == "vad":
            self._open_mic()
        self.emit("status", state="listening" if mode != "off" else "off")

    def _open_mic(self) -> None:
        if self.mic is not None:
            return
        try:
            from .audio import Microphone

            self.mic = Microphone()
            self.mic.start()
        except Exception as e:
            self.mic = None
            self.mode = "off"
            self.emit("error", text=f"The microphone isn't available: {e}", mic=True)
            return
        self.mic_run.set()
        self.mic_thread = threading.Thread(target=self._mic_loop, daemon=True)
        self.mic_thread.start()

    def _close_mic(self) -> None:
        self.mic_run.clear()
        if self.mic_thread is not None:
            self.mic_thread.join(timeout=1)
            self.mic_thread = None
        if self.mic is not None:
            try:
                self.mic.close()
            except Exception:
                pass
            self.mic = None
        self.detector.reset()
        self.vad.reset()

    def ptt(self, down: bool) -> None:
        if down:
            if self.mode == "off":
                self.mode = "ptt"
            if self.mode != "ptt":
                return  # hands-free is on: the key does nothing extra
            self.ptt_audio = []
            self.vad.reset()
            self._open_mic()
            if self.mic is None:
                return
            self.ptt_down.set()
            self.emit("speech_start")
            self.emit("status", state="hearing")
        else:
            if not self.ptt_down.is_set():
                return
            # Keep the last breath of the word: the key goes up a moment after you stop.
            time.sleep(0.25)
            self.ptt_down.clear()
            audio = np.concatenate(self.ptt_audio) if self.ptt_audio else np.zeros(0, np.int16)
            self.ptt_audio = []
            if self.mode == "ptt":
                self._close_mic()
            self.emit("status", state="thinking")
            threading.Thread(target=self._transcribe, args=(audio,), daemon=True).start()

    def _mic_loop(self) -> None:
        last_voice = 0.0
        while self.mic_run.is_set() and self.mic is not None:
            try:
                chunk = self.mic.chunks.get(timeout=0.2)
            except queue.Empty:
                continue
            if self.ptt_down.is_set():
                self.ptt_audio.append(chunk)
                continue
            if self.mode != "vad":
                continue
            prob = self.vad(chunk)
            if self.speaking:
                last_voice = time.monotonic()
                if not self.barge_in:
                    self.detector.reset()
                    continue
                ev = self.detector.feed(prob, chunk, threshold=0.85,
                                        min_speech_chunks=max(1, round(0.35 / CHUNK_SEC)))
            elif time.monotonic() - last_voice < 0.4:
                self.detector.reset()  # the tail of our own voice in the microphone
                continue
            else:
                ev = self.detector.feed(prob, chunk)
            if ev is None:
                continue
            if ev.kind == "start":
                if self.speaking:
                    self.stop()  # silence at once; the app stops the generation
                    self.emit("barge_in")
                self.emit("speech_start")
                self.emit("status", state="hearing")
            elif ev.kind == "end":
                self.emit("status", state="thinking")
                threading.Thread(target=self._transcribe, args=(ev.audio,), daemon=True).start()

    def _transcribe(self, audio: np.ndarray) -> None:
        try:
            if len(audio) < SAMPLE_RATE * 0.3:
                self.emit("transcript", text="", kind="")
                return
            with self.stt_lock:
                if self.stt is None:
                    self.emit("loading", what="ears")
                    from .stt import make_stt

                    self.stt = make_stt(self.whisper_arg, self.language)
                text = self.stt.transcribe(audio)
            if looks_like_hallucination(text):
                text = ""
            self.emit("transcript", text=text, kind=classify(text, self.name) if text else "")
        except Exception as e:
            self.emit("error", text=f"Listening failed: {e}")
            self.emit("transcript", text="", kind="")

    # -- commands ----------------------------------------------------------------------
    def handle(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        if cmd == "listen":
            self.set_mode(msg.get("mode", "off"), bool(msg.get("barge_in", True)))
        elif cmd == "ptt":
            threading.Thread(target=self.ptt, args=(bool(msg.get("down")),), daemon=True).start()
        elif cmd == "say":
            self.say(str(msg.get("text", "")), bool(msg.get("first")))
        elif cmd == "bridge":
            self.bridge(str(msg.get("kind", "erzaehlung")))
        elif cmd == "stop":
            self.stop()
        elif cmd == "transcribe":
            audio = read_wav16k(str(msg.get("path", "")))
            self.emit("status", state="thinking")
            threading.Thread(target=self._transcribe, args=(audio,), daemon=True).start()
        elif cmd == "quit":
            self.quit.set()

    def run(self) -> None:
        self.load()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                self.handle(json.loads(line))
            except Exception as e:
                self.emit("error", text=f"Bad command: {e}")
            if self.quit.is_set():
                break
        self._close_mic()
        self.player.stop()


def synth_to_wav(text: str, path: str, voice: str | None = None) -> None:
    from .tts import PiperTTS, find_voice

    found = find_voice(voice)
    if found is None:
        raise SystemExit("No voice file found. Run scripts/xool-setup.sh.")
    tts = PiperTTS(found)
    audio = tts.synth(clean_for_speech(text))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(tts.sample_rate)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
