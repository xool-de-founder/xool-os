#!/usr/bin/env python3
"""Automated proof of the voice, with WAV files instead of microphone and speakers.

Run it with the voice venv's Python:

  ~/Library/Application\\ Support/Xool/voice/venv/bin/python scripts/voice-e2e.py [--out DIR] [--model gemma4:12b]

It starts the sidecar (`--fake-mic --record`), says things to it with macOS's own
German voices (so Whisper hears a voice that is not Piper's), lets a local Ollama
model answer in the app's spoken style, sends the sentences back for speaking and
checks the recording of what would have come out of the speakers:

  1. an ordinary question  -> heard, answered, spoken (the output WAV is transcribed and checked)
  2. a question that needs the web -> a bridge phrase from the web-search group
  3. barge-in while it speaks -> it falls silent; and it does NOT interrupt itself (echo gate)
  4. a sentence not meant for it  -> the judgement says "not named"; the app ignores it
  5. latencies

Results go to DIR/report.json and DIR/*.wav.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Resources" / "voice"))

from xool_voice.phrasen import PHRASES  # noqa: E402


class Sidecar:
    def __init__(self, extra: list[str] | None = None):
        env = dict(os.environ, PYTHONPATH=str(ROOT / "Resources" / "voice"), PYTHONUNBUFFERED="1")
        self.p = subprocess.Popen(
            [sys.executable, "-m", "xool_voice", "--serve", "--fake-mic", "--record", "--language", "de"] + (extra or []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(None if os.environ.get("XOOL_VOICE_TRACE") else subprocess.DEVNULL), text=True, env=env,
            cwd=str(ROOT / "Resources" / "voice"))
        self.events: list[tuple[float, dict]] = []
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self.cv:
                self.events.append((time.monotonic(), ev))
                self.cv.notify_all()

    def send(self, **msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def mark(self) -> int:
        with self.cv:
            return len(self.events)

    def wait(self, name: str, since: int = 0, timeout: float = 60, where=None):
        end = time.monotonic() + timeout
        with self.cv:
            while True:
                for i in range(since, len(self.events)):
                    t, ev = self.events[i]
                    if ev.get("ev") == name and (where is None or where(ev)):
                        return t, ev
                left = end - time.monotonic()
                if left <= 0:
                    return None, None
                self.cv.wait(left)

    def find(self, name: str, since: int = 0):
        with self.cv:
            return [(t, e) for t, e in self.events[since:] if e.get("ev") == name]

    def close(self):
        try:
            self.send(cmd="quit")
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def say_wav(text: str, path: Path, voice: str = "Anna") -> Path:
    aiff = path.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(path)], check=True)
    aiff.unlink()
    return path


def voice_onset(path: Path) -> float:
    """Seconds of near-silence at the start of a WAV (so latency is counted from the first sound)."""
    with wave.open(str(path)) as w:
        rate = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)
    loud = np.nonzero(np.abs(a) > 0.04 * np.abs(a).max())[0]
    return float(loud[0] / rate) if len(loud) else 0.0


def wav_seconds(path: Path) -> float:
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


SPOKEN = (
    "Du bist Jarvis, ein Sprachassistent. Der Nutzer spricht mit dir und deine Antwort wird vorgelesen. "
    "Antworte auf Deutsch in einem bis drei kurzen, natürlichen Sätzen. Kein Markdown, keine Listen, keine Links, "
    "keine Aufzählungszeichen. Zahlen und Namen so schreiben, wie man sie spricht. /no_think"
)


def llm_answer(model: str, question: str, system: str = SPOKEN):
    """Streams the model's answer; yields (text piece, seconds since the request)."""
    body = json.dumps({"model": model, "stream": True, "think": False, "options": {"num_ctx": 4096, "temperature": 0.5},
                       "messages": [{"role": "system", "content": system}, {"role": "user", "content": question}]}).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", body, {"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=120) as r:
        for line in r:
            d = json.loads(line)
            piece = d.get("message", {}).get("content", "")
            if piece:
                yield piece, time.monotonic() - t0
            if d.get("done"):
                break


def sentences(stream):
    """The app's SpeechChunker in short: the first piece may end at a comma after four words."""
    buf, first = "", True
    for piece, t in stream:
        buf += piece
        while True:
            m = re.search(r"[.!?…]\s", buf)
            if first and not m:
                m2 = re.search(r"^(\S+\s+){3,}\S+[,;:]\s", buf)
                if m2:
                    m = m2
            if not m:
                break
            cut = m.end()
            yield buf[:cut].strip(), t
            buf, first = buf[cut:], False
    if buf.strip():
        yield buf.strip(), t


def transcribe_wav(path: Path) -> str:
    from xool_voice.server import read_wav16k
    from xool_voice.stt import make_stt

    global _STT
    try:
        _STT
    except NameError:
        _STT = make_stt(None, "de")
    return _STT.transcribe(read_wav16k(str(path)))


def run_turn(sc: Sidecar, wav: Path, model: str, out: Path, tag: str, answer_with: str | None = None) -> dict:
    """Says `wav` into the fake microphone, answers like the app does, saves the output WAV."""
    since = sc.mark()
    sc.send(cmd="feed", path=str(wav), delay=0.2)
    t_feed = time.monotonic() + 0.2
    t_tr, tr = sc.wait("transcript", since, timeout=60, where=lambda e: e.get("text"))
    r: dict = {"tag": tag}
    if tr is None:
        r["error"] = "no transcript"
        return r
    r.update(heard=tr["text"], route=tr.get("route"), kind=tr.get("kind"), tools=tr.get("tools"), named=tr.get("named"),
             ms_stt=tr.get("ms_stt"), ms_after_end=tr.get("ms_after_end"), early=tr.get("early"))
    # The app: a bridge phrase at once, then the answer sentence by sentence.
    sc.send(cmd="bridge", kind=tr.get("kind", "erzaehlung"))
    t0 = time.monotonic()
    first = True
    said: list[str] = []
    for sentence, t_llm in sentences(llm_answer(model, answer_with or tr["text"])):
        if first:
            r["ms_llm_first_sentence"] = round(t_llm * 1000)
        sc.send(cmd="say", text=sentence, first=first)
        said.append(sentence)
        first = False
    r["answer"] = " ".join(said)
    t_s, _ = sc.wait("idle", sc.mark() - 0 if False else since, timeout=60)
    sc.send(cmd="save_out", path=str(out / f"{tag}-out.wav"))
    sc.wait("saved", since, timeout=10)
    br = sc.find("bridge", since)
    if br:
        r["bridge"] = br[0][1]["text"]
        r["bridge_group"] = br[0][1].get("kind")
        r["ms_bridge_after_end"] = br[0][1].get("ms")
    sounds = sc.find("sound", since)
    for _, s in sounds:
        if s.get("kind") == "say" and "ms_first_sound" not in r:
            r["ms_first_sound"] = s.get("ms")
        if s.get("kind") == "bridge" and "ms_bridge_sound" not in r:
            r["ms_bridge_sound"] = s.get("ms")
    return r


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs" / "voice-e2e"))
    ap.add_argument("--model", default="gemma4:12b")
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    report: dict = {"model": a.model, "turns": [], "checks": {}}
    checks = report["checks"]

    # input WAVs, spoken by macOS's own voices
    wavs = {
        "wissen": say_wav("Jarvis, wie heißt die Hauptstadt von Frankreich und was ist dort besonders bekannt?", out / "in-wissen.wav"),
        "web": say_wav("Jarvis, such mir bitte im Internet die aktuellen Nachrichten zu Apple.", out / "in-web.wav", "Anna"),
        "interrupt": say_wav("Stopp, warte mal kurz, ich habe eine andere Frage.", out / "in-interrupt.wav", "Anna"),
        "nicht-gemeint": say_wav("Schatz, kannst du bitte den Tisch decken, das Essen ist gleich fertig.", out / "in-nicht-gemeint.wav", "Anna"),
    }

    sc = Sidecar(["--echo-gain", "0.15", "--pause", "0.5"])
    try:
        t, _ = sc.wait("warm", timeout=180)
        assert t, "the sidecar didn't get warm"
        sc.wait("bridges", timeout=300)
        sc.send(cmd="listen", mode="vad", barge_in=True, pause=0.5)
        sc.wait("status", timeout=5)

        # 1. an ordinary question
        r = run_turn(sc, wavs["wissen"], a.model, out, "1-wissen")
        report["turns"].append(r)
        heard_ok = "frankreich" in r.get("heard", "").lower()
        spoken = transcribe_wav(out / "1-wissen-out.wav") if (out / "1-wissen-out.wav").exists() else ""
        r["output_heard_by_whisper"] = spoken
        checks["1 question heard"] = heard_ok
        checks["1 route is knowledge, no tools"] = r.get("route") == "wissen" and r.get("tools") is False
        checks["1 answer audible (Paris in the output WAV)"] = "paris" in spoken.lower()
        checks["1 no markdown spoken"] = not re.search(r"[*#`]", spoken)

        # 2. the web
        r = run_turn(sc, wavs["web"], a.model, out, "2-web")
        report["turns"].append(r)
        checks["2 route is web"] = r.get("route") == "web" and r.get("tools") is True
        checks["2 bridge phrase announces the search"] = r.get("bridge") in PHRASES["websuche"]
        spoken2 = transcribe_wav(out / "2-web-out.wav") if (out / "2-web-out.wav").exists() else ""
        r["output_heard_by_whisper"] = spoken2

        # 3a. no self-interruption: a long answer with echo in the microphone and nobody talking
        since = sc.mark()
        long_text = ("Hier ist eine längere Antwort, damit man hört, dass ich mich nicht selbst unterbreche. "
                     "Die Hauptstadt von Frankreich ist Paris, eine Stadt mit über zwei Millionen Einwohnern. "
                     "Sie liegt an der Seine und ist bekannt für den Eiffelturm, den Louvre und viele Cafés.")
        for i, s in enumerate(re.split(r"(?<=[.!?])\s+", long_text)):
            sc.send(cmd="say", text=s, first=i == 0)
        sc.wait("idle", since, timeout=60)
        selfb = sc.find("barge_in", since)
        checks["3a no self barge-in with echo in the microphone"] = not selfb
        report["echo_g_learned"] = None

        # 3b. barge-in: it speaks, you talk over it
        since = sc.mark()
        for i, s in enumerate(re.split(r"(?<=[.!?])\s+", long_text + " Und noch ein Satz, der nie zu Ende gesprochen wird, weil jemand dazwischen redet.")):
            sc.send(cmd="say", text=s, first=i == 0)
        sc.wait("speaking", since, timeout=10, where=lambda e: e.get("on"))
        time.sleep(2.0)
        sc.send(cmd="feed", path=str(wavs["interrupt"]), delay=0.0)
        t_feed = time.monotonic()
        t_b, b = sc.wait("barge_in", since, timeout=10)
        onset = voice_onset(wavs["interrupt"])
        checks["3b barge-in detected"] = b is not None
        if b:
            report["barge_in"] = {"ms_from_voice_onset_to_silence": round((t_b - t_feed - onset) * 1000), "wav_onset_ms": round(onset * 1000), **{k: b[k] for k in ("ms_stop", "ms_total")}}
            checks["3b stop took < 150 ms after the decision"] = b["ms_stop"] < 150
        sc.wait("idle", since, timeout=10)
        sc.send(cmd="save_out", path=str(out / "3b-bargein-out.wav"))
        sc.wait("saved", since, timeout=10)
        full = wav_seconds(out / "3a-dummy.wav") if False else None
        t_tr, tr = sc.wait("transcript", since, timeout=30, where=lambda e: e.get("text"))
        report["barge_in_followup_heard"] = tr.get("text") if tr else None
        checks["3b what was said over it is heard"] = bool(tr and "frage" in tr["text"].lower())

        # 4. a sentence not meant for it
        r = run_turn_heard_only(sc, wavs["nicht-gemeint"])
        report["turns"].append(r)
        checks["4 'not meant for Jarvis': no name in the sentence"] = r.get("named") is False

        report["bridge_library"] = {"phrases": len({p for g in PHRASES.values() for p in g}), "groups": len(PHRASES)}
        ok = all(checks.values())
    finally:
        sc.close()
    (out / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print("\n".join(f"{'OK  ' if v else 'FAIL'} {k}" for k, v in checks.items()))
    return 0 if ok else 1


def run_turn_heard_only(sc: Sidecar, wav: Path) -> dict:
    since = sc.mark()
    sc.send(cmd="feed", path=str(wav), delay=0.2)
    t, tr = sc.wait("transcript", since, timeout=60, where=lambda e: e.get("text"))
    return {"tag": "4-nicht-gemeint", "heard": tr and tr["text"], "named": tr and tr.get("named"), "route": tr and tr.get("route")}


if __name__ == "__main__":
    sys.exit(main())
