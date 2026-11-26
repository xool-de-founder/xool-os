"""Stand-ins for the speakers and the microphone, for tests without a sound card.

`NullPlayer` plays nothing but takes the time the audio would take, and can
keep a recording of what would have been heard (the "output WAV").
`FakeMic` is a microphone that hears silence, plus any WAV file you inject at
a time you choose, plus (optionally) an echo of what the player is saying, so
barge-in and the echo gate can be tested the way a room would test them.
"""

from __future__ import annotations

import queue
import threading
import time
import wave

import numpy as np

from .audio import resample
from .vad import CHUNK, CHUNK_SEC, SAMPLE_RATE


class NullPlayer:
    def __init__(self, sample_rate: int, record: bool = False):
        self.sample_rate = sample_rate
        self._until = 0.0
        self.last_sound = 0.0
        self.played_seconds = 0.0
        self.record = record
        self.t0 = time.monotonic()
        self._segs: list[list] = []  # [start, audio]  (monotonic seconds, float32)
        self._lock = threading.Lock()

    def play(self, audio, on_start=None):
        now = time.monotonic()
        start = max(now, self._until)
        self._until = start + len(audio) / self.sample_rate
        self.played_seconds += len(audio) / self.sample_rate
        with self._lock:
            self._segs.append([start, np.asarray(audio, np.float32)])
        if on_start:
            if start > now:
                threading.Timer(start - now, on_start).start()
            else:
                on_start()

    def stop(self):
        now = time.monotonic()
        self._until = 0.0
        with self._lock:
            for seg in self._segs:
                keep = int(max(0.0, now - seg[0]) * self.sample_rate)
                if keep < len(seg[1]):
                    seg[1] = seg[1][:keep]

    @property
    def busy(self) -> bool:
        return time.monotonic() < self._until

    @property
    def level(self) -> float:
        a = self.block(time.monotonic() - 0.032, 0.032)
        self.last_sound = time.monotonic() if len(a) and float(np.abs(a).max()) > 1e-4 else self.last_sound
        return float(np.sqrt(np.mean(a ** 2))) if len(a) else 0.0

    def block(self, t_start: float, seconds: float) -> np.ndarray:
        """What was playing in the window [t_start, t_start+seconds), at the player's rate."""
        n = int(seconds * self.sample_rate)
        out = np.zeros(n, np.float32)
        with self._lock:
            for start, audio in self._segs:
                off = int((start - t_start) * self.sample_rate)
                lo, hi = max(0, off), min(n, off + len(audio))
                if hi > lo:
                    out[lo:hi] += audio[lo - off:hi - off]
        return out

    def first_sound_at(self) -> float | None:
        with self._lock:
            return min((s[0] for s in self._segs if len(s[1])), default=None)

    def save(self, path: str, since: float | None = None) -> float:
        """The recording as a WAV; returns its length in seconds."""
        with self._lock:
            segs = [(s, a) for s, a in self._segs if len(a)]
        if not segs:
            audio = np.zeros(0, np.float32)
        else:
            t0 = since if since is not None else min(s for s, _ in segs)
            end = max(s + len(a) / self.sample_rate for s, a in segs)
            audio = np.zeros(int((end - t0) * self.sample_rate) + 1, np.float32)
            for s, a in segs:
                off = max(0, int((s - t0) * self.sample_rate))
                audio[off:off + len(a)] += a[: max(0, len(audio) - off)]
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.sample_rate)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
        return len(audio) / self.sample_rate


class FakeMic:
    """A microphone with no hardware: silence, injected WAVs, and the room's echo."""

    def __init__(self, player=None, echo_gain: float = 0.0, noise: float = 4.0):
        self.chunks: queue.Queue[np.ndarray] = queue.Queue()
        self.player = player
        self.echo_gain = echo_gain
        self.noise = noise
        self._inject: list[tuple[float, np.ndarray]] = []  # (due, int16 16k audio)
        self._active: np.ndarray | None = None
        self._pos = 0
        self._run = threading.Event()
        self._thread: threading.Thread | None = None
        self.injected_at: float | None = None
        self._rng = np.random.default_rng(1)
        self._lock = threading.Lock()

    def inject(self, audio16k: np.ndarray, delay: float = 0.0) -> float:
        due = time.monotonic() + delay
        with self._lock:
            self._inject.append((due, audio16k.astype(np.int16)))
        return due

    def start(self) -> None:
        self._run.set()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        nxt = time.monotonic()
        while self._run.is_set():
            nxt += CHUNK_SEC
            now = time.monotonic()
            if nxt > now:
                time.sleep(nxt - now)
            chunk = (self._rng.standard_normal(CHUNK) * self.noise).astype(np.float32)
            with self._lock:
                if self._active is None and self._inject and self._inject[0][0] <= time.monotonic():
                    self._active, self._pos = self._inject.pop(0)[1], 0
                    self.injected_at = time.monotonic()
                if self._active is not None:
                    part = self._active[self._pos:self._pos + CHUNK].astype(np.float32)
                    chunk[: len(part)] += part
                    self._pos += CHUNK
                    if self._pos >= len(self._active):
                        self._active = None
            if self.echo_gain > 0 and self.player is not None:
                echo = self.player.block(time.monotonic() - CHUNK_SEC, CHUNK_SEC)
                if len(echo) and float(np.abs(echo).max()) > 0:
                    echo16 = resample(echo, self.player.sample_rate, SAMPLE_RATE)[:CHUNK]
                    chunk[: len(echo16)] += echo16 * 32768.0 * self.echo_gain
            self.chunks.put(np.clip(chunk, -32768, 32767).astype(np.int16))

    def close(self) -> None:
        self._run.clear()
        if self._thread is not None:
            self._thread.join(timeout=1)
