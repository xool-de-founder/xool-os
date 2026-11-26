"""Microphone input and gap-free speaker output (sounddevice / PortAudio)."""

from __future__ import annotations

import queue
import threading
import time
from collections import deque
from typing import Callable

import numpy as np

from .vad import CHUNK, SAMPLE_RATE


def resample(audio: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate or len(audio) == 0:
        return audio
    n = int(round(len(audio) * dst_rate / src_rate))
    x_old = np.linspace(0.0, 1.0, num=len(audio), endpoint=False)
    x_new = np.linspace(0.0, 1.0, num=n, endpoint=False)
    return np.interp(x_new, x_old, audio).astype(audio.dtype)


class Player:
    """Plays queued audio chunks back to back. stop() silences it at once (for barge-in)."""

    def __init__(self, sample_rate: int, device=None):
        import sounddevice as sd

        self.sample_rate = sample_rate
        self._segments: deque[list] = deque()  # [audio, pos, on_start]
        self._lock = threading.Lock()
        self.last_sound = 0.0
        self._stream = sd.OutputStream(
            samplerate=sample_rate, channels=1, dtype="float32",
            callback=self._callback, device=device, latency="low", blocksize=0,
        )
        self._stream.start()

    def _callback(self, outdata, frames, _time, _status):
        out = outdata[:, 0]
        filled = 0
        with self._lock:
            while filled < frames and self._segments:
                seg = self._segments[0]
                audio, pos, on_start = seg
                if pos == 0 and on_start is not None:
                    seg[2] = None
                    try:
                        on_start()
                    except Exception:
                        pass
                n = min(frames - filled, len(audio) - pos)
                out[filled:filled + n] = audio[pos:pos + n]
                filled += n
                seg[1] = pos + n
                if seg[1] >= len(audio):
                    self._segments.popleft()
        if filled < frames:
            out[filled:] = 0.0
        if filled:
            self.last_sound = time.monotonic()

    def play(self, audio: np.ndarray, on_start: Callable[[], None] | None = None) -> None:
        if len(audio) == 0:
            return
        with self._lock:
            self._segments.append([audio.astype(np.float32), 0, on_start])

    def stop(self) -> None:
        with self._lock:
            self._segments.clear()

    @property
    def busy(self) -> bool:
        with self._lock:
            return bool(self._segments)

    def wait(self, timeout: float = 60) -> None:
        end = time.monotonic() + timeout
        while self.busy and time.monotonic() < end:
            time.sleep(0.02)

    def close(self) -> None:
        self._stream.stop()
        self._stream.close()


class Microphone:
    """Delivers 32 ms int16 chunks at 16 kHz through a queue."""

    def __init__(self, device=None):
        import sounddevice as sd

        self.chunks: queue.Queue[np.ndarray] = queue.Queue()
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="int16", blocksize=CHUNK,
            callback=self._callback, device=device, latency="low",
        )

    def _callback(self, indata, _frames, _time, _status):
        self.chunks.put(indata[:, 0].copy())

    def start(self) -> None:
        self._stream.start()

    def close(self) -> None:
        self._stream.stop()
        self._stream.close()
