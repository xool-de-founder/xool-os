"""The sidecar's loop: JSON lines on stdin and stdout.

The app (VoiceBridge.swift) sends commands, one JSON object per line:
  {"cmd":"listen","mode":"off"|"ptt"|"vad","barge_in":true,"pause":0.5}
  {"cmd":"ptt","down":true|false}        push-to-talk key pressed / released
  {"cmd":"say","text":"…","first":true}  speak one sentence (queued, in order)
  {"cmd":"bridge","kind":"frage"}        a ready-made bridge phrase, if nothing is being said
  {"cmd":"stop"}                         silence now and forget what is queued
  {"cmd":"transcribe","path":"x.wav"}    test input: a WAV file instead of the microphone
  {"cmd":"wake","on":true}               listen for "Hey Jarvis" (openWakeWord, if installed)
  {"cmd":"feed","path":"x.wav","delay":0}   tests: a WAV in place of the microphone (--fake-mic)
  {"cmd":"save_out","path":"out.wav"}    tests: what would have come out of the speakers (--record)
  {"cmd":"quit"}
and gets events back, one per line:
  ready{stt,tts,vad,output,input}  partial{text}  loading{what}  loaded{what}  warm{bridges}  status{state}  speech_start
  barge_in{ms_stop,ms_total}  transcript{text,kind,route,tools,named,ms_stt,ms_after_end}
  speaking{on}  idle  bridge{text,ms}  sound{kind,ms}  wake  error{text}

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
from collections import deque
from pathlib import Path

import numpy as np

from .testaudio import FakeMic, NullPlayer

from .bruecken import FillerBank, strip_leading_filler
from .urteil import judge
from .text import clean_for_speech, looks_like_hallucination
from .vad import CHUNK_SEC, SAMPLE_RATE, TurnDetector, make_vad


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


class _Spec:
    """A transcription started early, in the first moments of a pause: if you then go on
    talking it is thrown away; if the pause lasts, the answer is already there."""

    def __init__(self):
        self.done = threading.Event()
        self.text = ""
        self.ms = 0.0
        self.alive = True


class Server:
    #: A pause this long starts transcribing early (see _Spec).
    SPEC_AFTER = 0.22
    #: How often the live text is refreshed while you talk, and how much of the turn it reads (seconds).
    PARTIAL_EVERY = 0.45
    PARTIAL_MAX = 20.0

    def __init__(self, voice: str | None = None, whisper: str | None = None, speed: float = 1.05,
                 pause: float = 0.5, null_audio: bool = False, name: str = "Jarvis", language: str = "de",
                 record: bool = False, fake_mic: bool = False, echo_gain: float = 0.0,
                 cache_dir: str | None = None, wake: bool = False):
        self.language = language
        self.out = sys.stdout
        sys.stdout = sys.stderr  # nothing but events may reach the real stdout
        self.lock_out = threading.Lock()
        self.name, self.speed, self.pause = name, speed, pause
        self.voice_arg, self.whisper_arg, self.null_audio = voice, whisper, null_audio or record or fake_mic
        self.record, self.fake_mic, self.echo_gain = record or fake_mic, fake_mic, echo_gain
        self.cache_dir = cache_dir
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
        # Timing of the last turn, for the latency events.
        self.t_end = 0.0  # you stopped (the pause was confirmed)
        self.t_stt_done = 0.0
        self.announced_first = True
        self.spec: _Spec | None = None
        # Live text while you talk: every PARTIAL_EVERY seconds the speech so far is understood again.
        self.turn_id = 0
        self._partial_busy = False
        self._partial_at = 0.0
        self._partial_last = ""
        # Echo gate: how much of our own voice comes back in the microphone.
        self.echo_g = 0.25
        self._echo_cal: list[float] = []
        self._out_hist: deque = deque(maxlen=5)
        self._speak_since = 0.0
        self.wake_on = False
        self.wake = None
        self.wake_load = False

    # -- events ------------------------------------------------------------------------
    def emit(self, ev: str, **data) -> None:
        with self.lock_out:
            self.out.write(json.dumps({"ev": ev, **data}, ensure_ascii=False) + "\n")
            self.out.flush()

    def log(self, text: str) -> None:
        print(text, file=sys.stderr, flush=True)

    # -- loading -----------------------------------------------------------------------
    def load(self) -> None:
        from .tts import APP_HOME, PiperTTS, find_voice

        path = find_voice(self.voice_arg)
        if path is None:
            self.emit("error", text="No voice file found. Set up the voice first.", fatal=True)
            raise SystemExit(2)
        self.tts = PiperTTS(path, speed=self.speed)
        if self.null_audio:
            self.player = NullPlayer(self.tts.sample_rate, record=self.record)
        else:
            from .audio import Player

            self.player = Player(self.tts.sample_rate)
        self.vad, vad_name = make_vad()
        cache = Path(self.cache_dir) if self.cache_dir else APP_HOME / "cache" / "bridges"
        self.fillers = FillerBank(self.tts, cache_dir=cache)
        self.fillers.prepare(background=True)
        threading.Thread(target=self._say_worker, daemon=True).start()
        threading.Thread(target=self._speaking_monitor, daemon=True).start()
        threading.Thread(target=self._announce_warm, daemon=True).start()
        self.emit("ready", tts=self.tts.name, vad=vad_name, null_audio=self.null_audio, **self._devices())
        threading.Thread(target=self._load_stt, daemon=True).start()

    @staticmethod
    def _devices() -> dict:
        """Which speaker and microphone this process will use (for the voice log)."""
        try:
            import sounddevice as sd

            out = sd.query_devices(sd.default.device[1])["name"] if sd.default.device[1] >= 0 else "none"
            inp = sd.query_devices(sd.default.device[0])["name"] if sd.default.device[0] >= 0 else "none"
            return {"output": out, "input": inp}
        except Exception as e:  # pragma: no cover
            return {"output": f"unknown ({e})", "input": "unknown"}

    def _announce_warm(self) -> None:
        self.fillers.ready.wait()
        self.emit("bridges", count=self.fillers.count(), cached=self.fillers.loaded_from_cache)

    def _load_stt(self) -> None:
        try:
            self.emit("loading", what="ears")
            from .stt import make_stt, warmup

            with self.stt_lock:
                self.stt = make_stt(self.whisper_arg, self.language)
                warmup(self.stt)
            self.emit("loaded", what="ears", stt=self.stt.name)
            self.emit("warm")
        except Exception as e:
            self.emit("error", text=f"Speech recognition didn't load: {e}")

    # -- speaking ----------------------------------------------------------------------
    def say(self, text: str, first: bool = False) -> None:
        if first and self.bridged:
            text = strip_leading_filler(text)
        if first:
            self.bridged = False
            self.announced_first = False
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
                self.player.play(audio, on_start=self._first_sound)
            except Exception as e:
                self.emit("error", text=f"Speaking failed: {e}")
            finally:
                self.say_q.task_done()

    def _first_sound(self) -> None:
        if not self.announced_first:
            self.announced_first = True
            now = time.monotonic()
            self.emit("sound", kind="say", ms=round((now - self.t_end) * 1000) if self.t_end else None)

    def _speaking_monitor(self) -> None:
        while not self.quit.is_set():
            now = bool(self.player.busy) or self.say_q.unfinished_tasks > 0
            if now != self.speaking:
                self.speaking = now
                if now:
                    self._speak_since = time.monotonic()
                    self._echo_cal = []
                self.emit("speaking", on=now)
                if not now:
                    self.emit("idle")
            time.sleep(0.02)

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
        t_call = time.monotonic()

        def started():
            now = time.monotonic()
            self.emit("sound", kind="bridge", ms=round((now - self.t_end) * 1000) if self.t_end else None)

        self.player.play(audio, on_start=started)
        self.bridged = True
        self.announced_first = False
        self.emit("bridge", text=phrase, kind=kind, ms=round((t_call - self.t_end) * 1000) if self.t_end else None)

    # -- listening ---------------------------------------------------------------------
    def set_mode(self, mode: str, barge_in: bool = True, pause: float | None = None) -> None:
        self.barge_in = barge_in
        if pause is not None and pause != self.pause:
            self.pause = pause
            self.detector.end_silence_chunks = max(1, round(pause / CHUNK_SEC))
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
            if self.fake_mic:
                self.mic = FakeMic(self.player, self.echo_gain)
            else:
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
        self.spec = None

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
            self.t_end = time.monotonic()
            self.emit("status", state="thinking")
            threading.Thread(target=self._transcribe, args=(audio,), daemon=True).start()

    @staticmethod
    def _rms(chunk: np.ndarray) -> float:
        return float(np.sqrt(np.mean((chunk.astype(np.float32) / 32768.0) ** 2)))

    def _echo_ok(self, chunk: np.ndarray) -> bool:
        """While we speak: is this louder than our own voice coming back would be?"""
        rms = self._rms(chunk)
        self._out_hist.append(float(getattr(self.player, "level", 0.0)))
        out = max(self._out_hist)  # our voice has gaps between words; its envelope doesn't
        since = time.monotonic() - self._speak_since
        if since < 0.45:
            # The first moments of speaking: nobody is talking over it yet; learn how
            # much of the voice the microphone hears (speakers vs. headphones).
            if out > 0.02:
                self._echo_cal.append(rms / out)
                self.echo_g = max(0.0, float(np.percentile(self._echo_cal, 75)) * 1.2)
            return False
        return rms > max(0.012, self.echo_g * out * 1.5 + 0.006)

    def _mic_loop(self) -> None:
        last_voice = 0.0
        need, window = 5, 12  # a voice over ours: 5 of the last 12 chunks (0.4 s) clearly louder than the echo
        recent: deque = deque(maxlen=window)
        tail: deque = deque(maxlen=window)
        dead = 0  # chunks in a row that are exactly zero: macOS hands a process without permission silence, not an error
        while self.mic_run.is_set() and self.mic is not None:
            try:
                chunk = self.mic.chunks.get(timeout=0.2)
            except queue.Empty:
                continue
            if not self.fake_mic:
                dead = 0 if chunk.any() else dead + 1
                if dead == round(2.0 / CHUNK_SEC):
                    self.log("microphone: only silence for 2 s")
                    self.emit("error", text="The microphone only delivers silence. Allow Xool OS under Privacy & Security › "
                                            "Microphone (after an update macOS asks again), then switch Live off and on.", mic=True)
            if self.ptt_down.is_set():
                self.ptt_audio.append(chunk)
                continue
            if self.wake_on and self.wake is not None and not self.speaking:
                try:
                    if self.wake.feed(chunk):
                        self.emit("wake")
                        self.wake.reset()
                except Exception:
                    pass
            if self.mode != "vad":
                continue
            prob = self.vad(chunk)
            if self.speaking:
                last_voice = time.monotonic()
                tail.append(chunk)
                if not self.barge_in:
                    self.detector.reset()
                    continue
                recent.append(prob >= 0.85 and self._echo_ok(chunk))
                if sum(recent) < need:
                    continue
                # Somebody is talking over us.
                recent.clear()
                t0 = time.monotonic()
                self.stop()  # silence at once; the app stops the generation
                self.speaking = False
                stop_ms = round((time.monotonic() - t0) * 1000, 1)
                self.emit("barge_in", ms_stop=stop_ms, ms_total=round(stop_ms + 0.4 * 1000))
                self.emit("speaking", on=False)
                self.emit("idle")
                self.detector.start_with(list(tail)[-window:])
                self.emit("speech_start")
                self.emit("status", state="hearing")
                continue
            recent.clear()
            tail.clear()
            if time.monotonic() - last_voice < 0.4:
                self.detector.reset()  # the tail of our own voice in the microphone
                continue
            ev = self.detector.feed(prob, chunk)
            if ev is None:
                self._early_transcribe()  # (not on "end": the detector has just been reset)
                self._partial_tick()
                continue
            if ev.kind == "start":
                self.turn_id += 1
                self._partial_last = ""
                self.emit("speech_start")
                self.emit("status", state="hearing")
            elif ev.kind == "end":
                self.turn_id += 1
                self.t_end = time.monotonic()
                spec, self.spec = self.spec, None
                self.emit("status", state="thinking")
                threading.Thread(target=self._transcribe, args=(ev.audio, spec), daemon=True).start()

    def _partial_tick(self) -> None:
        """While you talk: understand what was said so far, about twice a second, and send it as `partial`."""
        d = self.detector
        now = time.monotonic()
        if (not d.in_speech or self._partial_busy or self.stt is None or self.spec is not None
                or now - self._partial_at < self.PARTIAL_EVERY or d.spoken_seconds < 0.6):
            return
        self._partial_busy = True
        self._partial_at = now
        turn = self.turn_id
        audio = d.audio_so_far().copy()[-int(self.PARTIAL_MAX * SAMPLE_RATE):]

        def work():
            try:
                if self.stt_lock.acquire(timeout=0.05):
                    self.stt_lock.release()
                else:
                    return  # the final transcription is running: it is the answer now
                text = self._stt(audio).strip()
                if text and turn == self.turn_id and text != self._partial_last and self.mode == "vad":
                    self._partial_last = text
                    self.emit("partial", text=text)
            except Exception:
                pass
            finally:
                self._partial_busy = False
                self._partial_at = time.monotonic()

        threading.Thread(target=work, daemon=True).start()

    def _early_transcribe(self) -> None:
        """In the first moments of a pause, start understanding what was said so far."""
        d = self.detector
        if not d.in_speech:
            self.spec = None
            return
        if d.silence_seconds == 0.0 and self.spec is not None:
            self.spec.alive = False  # you went on talking
            self.spec = None
        elif d.silence_seconds >= self.SPEC_AFTER and self.spec is None and d.spoken_seconds - d.silence_seconds >= 0.5:
            spec = self.spec = _Spec()
            audio = d.audio_so_far().copy()

            def work():
                t0 = time.monotonic()
                try:
                    spec.text = self._stt(audio)
                except Exception:
                    spec.text = ""
                    spec.alive = False
                spec.ms = (time.monotonic() - t0) * 1000
                spec.done.set()

            threading.Thread(target=work, daemon=True).start()

    def _stt(self, audio: np.ndarray) -> str:
        with self.stt_lock:
            if self.stt is None:
                self.emit("loading", what="ears")
                from .stt import make_stt

                self.stt = make_stt(self.whisper_arg, self.language)
            text = self.stt.transcribe(audio)
        return "" if looks_like_hallucination(text) else text

    def _transcribe(self, audio: np.ndarray, spec: "_Spec | None" = None) -> None:
        t0 = time.monotonic()
        try:
            if len(audio) < SAMPLE_RATE * 0.3:
                self.emit("transcript", text="", kind="")
                return
            if spec is not None and spec.alive:
                spec.done.wait(timeout=10)
                text, ms = spec.text, spec.ms
            else:
                text = self._stt(audio)
                ms = (time.monotonic() - t0) * 1000
            self.t_stt_done = time.monotonic()
            if not text:
                self.emit("transcript", text="", kind="")
                return
            j = judge(text, self.name)
            self.emit("transcript", text=text, ms_stt=round(ms),
                      ms_after_end=round((time.monotonic() - self.t_end) * 1000) if self.t_end else None,
                      early=bool(spec is not None and spec.alive), **j.as_dict())
        except Exception as e:
            self.emit("error", text=f"Listening failed: {e}")
            self.emit("transcript", text="", kind="")

    # -- wake word -----------------------------------------------------------------------
    def set_wake(self, on: bool) -> None:
        if not on:
            self.wake_on = False
            return
        if self.wake is not None:
            self.wake_on = True
            return
        if self.wake_load:
            return
        self.wake_load = True

        def load():
            try:
                from .wake import WakeWord

                self.wake = WakeWord()
                self.wake_on = True
                self.emit("loaded", what="wake")
            except Exception as e:
                self.emit("error", text=f"The wake word isn't available: {e}", wake=True)
            finally:
                self.wake_load = False

        threading.Thread(target=load, daemon=True).start()

    # -- commands ----------------------------------------------------------------------
    def handle(self, msg: dict) -> None:
        cmd = msg.get("cmd")
        if cmd == "listen":
            self.set_mode(msg.get("mode", "off"), bool(msg.get("barge_in", True)), msg.get("pause"))
        elif cmd == "ptt":
            threading.Thread(target=self.ptt, args=(bool(msg.get("down")),), daemon=True).start()
        elif cmd == "say":
            self.say(str(msg.get("text", "")), bool(msg.get("first")))
        elif cmd == "bridge":
            self.bridge(str(msg.get("kind", "erzaehlung")))
        elif cmd == "stop":
            self.stop()
        elif cmd == "wake":
            self.set_wake(bool(msg.get("on")))
        elif cmd == "transcribe":
            audio = read_wav16k(str(msg.get("path", "")))
            self.t_end = time.monotonic()
            self.emit("status", state="thinking")
            threading.Thread(target=self._transcribe, args=(audio,), daemon=True).start()
        elif cmd == "feed" and isinstance(self.mic, FakeMic):
            self.mic.inject(read_wav16k(str(msg.get("path", ""))), float(msg.get("delay", 0)))
        elif cmd == "save_out" and isinstance(self.player, NullPlayer):
            seconds = self.player.save(str(msg.get("path", "out.wav")))
            self.emit("saved", path=msg.get("path"), seconds=round(seconds, 2))
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
