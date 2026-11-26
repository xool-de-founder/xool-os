"""python -m xool_voice --serve        the sidecar (JSON lines on stdin/stdout)
python -m xool_voice --say "Hallo" --out hallo.wav   speak into a WAV file
python -m xool_voice --transcribe hallo.wav          what Whisper hears in a WAV file
python -m xool_voice --check                         is everything installed?"""

from __future__ import annotations

import argparse
import sys


def _bar(label: str, done: float) -> None:
    n = int(max(0.0, min(1.0, done)) * 20)
    print(f"{label} ▕{'█' * n}{'░' * (20 - n)}▏ {int(done * 100):3d}%", flush=True)


def prepare(a) -> int:
    """What the first conversation would otherwise wait for: the ears and the 300 ready-made phrases."""
    from .stt import DEFAULT_MLX_MODEL, DEFAULT_FW_MODEL, is_apple_silicon

    try:
        from huggingface_hub import snapshot_download
        from tqdm.auto import tqdm

        class Bar(tqdm):
            def update(self, n=1):
                r = super().update(n)
                if self.total and self.total > 1e6:
                    _bar("Ears (Whisper)", self.n / self.total)
                return r

        repo = a.whisper or (DEFAULT_MLX_MODEL if is_apple_silicon() else "Systran/faster-whisper-large-v3-turbo")
        _bar("Ears (Whisper)", 0)
        snapshot_download(repo, tqdm_class=Bar)
        _bar("Ears (Whisper)", 1)
    except Exception as e:  # the first conversation will fetch it instead
        print(f"The ears will download at the first conversation ({e}).", flush=True)
    try:  # the wake word "Hey Jarvis" (1 MB), so switching it on later needs no download
        from openwakeword.utils import download_models

        download_models(["hey_jarvis"])
    except Exception:
        pass
    from pathlib import Path

    from .bruecken import FillerBank
    from .tts import APP_HOME, PiperTTS, find_voice

    path = find_voice(a.voice)
    if path is None:
        print("No voice file found.", flush=True)
        return 1
    tts = PiperTTS(path, speed=a.speed)
    bank = FillerBank(tts, cache_dir=APP_HOME / "cache" / "bridges")
    total = bank.count()
    import threading
    import time

    bank.prepare(background=True)
    while not bank.ready.is_set():
        _bar("Phrases", len(bank.audio) / max(1, total))
        time.sleep(1.0)
    _bar("Phrases", 1)
    print(f"{total} bridge phrases ready.", flush=True)
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="xool_voice")
    p.add_argument("--serve", action="store_true")
    p.add_argument("--null-audio", action="store_true", help="no speaker, no real playback (tests)")
    p.add_argument("--voice")
    p.add_argument("--whisper")
    p.add_argument("--language", default="de", help="what you speak (Whisper language code)")
    p.add_argument("--speed", type=float, default=1.05)
    p.add_argument("--pause", type=float, default=0.5)
    p.add_argument("--name", default="Jarvis", help="the assistant's name (for \"was I addressed?\")")
    p.add_argument("--record", action="store_true", help="tests: keep what would be played (save_out)")
    p.add_argument("--fake-mic", action="store_true", help="tests: no microphone, WAV files via feed")
    p.add_argument("--echo-gain", type=float, default=0.0, help="tests: how much of the voice the fake microphone hears")
    p.add_argument("--cache-dir")
    p.add_argument("--wake", action="store_true")
    p.add_argument("--say")
    p.add_argument("--out")
    p.add_argument("--transcribe")
    p.add_argument("--check", action="store_true")
    p.add_argument("--prepare", action="store_true", help="download Whisper and make the bridge phrases (setup)")
    a = p.parse_args(argv)

    if a.check:
        missing = []
        for mod in ("numpy", "sounddevice", "pysilero_vad", "piper"):
            try:
                __import__(mod)
            except Exception:
                missing.append(mod)
        from .stt import is_apple_silicon

        try:
            __import__("mlx_whisper" if is_apple_silicon() else "faster_whisper")
        except Exception:
            missing.append("whisper")
        from .tts import find_voice

        if find_voice(a.voice) is None:
            missing.append("voice file")
        print("ok" if not missing else "missing: " + ", ".join(missing))
        return 0 if not missing else 1
    if a.prepare:
        return prepare(a)
    if a.say:
        from .server import synth_to_wav

        synth_to_wav(a.say, a.out or "say.wav", a.voice)
        print(a.out or "say.wav")
        return 0
    if a.transcribe:
        from .server import read_wav16k
        from .stt import make_stt

        print(make_stt(a.whisper, a.language).transcribe(read_wav16k(a.transcribe)))
        return 0
    if a.serve:
        from .server import Server

        Server(a.voice, a.whisper, a.speed, a.pause, a.null_audio, name=a.name, language=a.language, record=a.record,
               fake_mic=a.fake_mic, echo_gain=a.echo_gain, cache_dir=a.cache_dir, wake=a.wake).run()
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
