"""python -m xool_voice --serve        the sidecar (JSON lines on stdin/stdout)
python -m xool_voice --say "Hallo" --out hallo.wav   speak into a WAV file
python -m xool_voice --transcribe hallo.wav          what Whisper hears in a WAV file
python -m xool_voice --check                         is everything installed?"""

from __future__ import annotations

import argparse
import sys


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="xool_voice")
    p.add_argument("--serve", action="store_true")
    p.add_argument("--null-audio", action="store_true", help="no speaker, no real playback (tests)")
    p.add_argument("--voice")
    p.add_argument("--whisper")
    p.add_argument("--speed", type=float, default=1.05)
    p.add_argument("--pause", type=float, default=0.6)
    p.add_argument("--say")
    p.add_argument("--out")
    p.add_argument("--transcribe")
    p.add_argument("--check", action="store_true")
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
    if a.say:
        from .server import synth_to_wav

        synth_to_wav(a.say, a.out or "say.wav", a.voice)
        print(a.out or "say.wav")
        return 0
    if a.transcribe:
        from .server import read_wav16k
        from .stt import make_stt

        print(make_stt(a.whisper).transcribe(read_wav16k(a.transcribe)))
        return 0
    if a.serve:
        from .server import Server

        Server(a.voice, a.whisper, a.speed, a.pause, a.null_audio).run()
        return 0
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
