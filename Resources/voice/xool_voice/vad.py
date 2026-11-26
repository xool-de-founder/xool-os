"""Voice activity detection: notice when you start and stop talking."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16000
CHUNK = 512  # 32 ms at 16 kHz – the window size Silero VAD expects
CHUNK_SEC = CHUNK / SAMPLE_RATE


class EnergyVAD:
    """Very simple fallback if Silero is not available."""

    def __init__(self, level: float = 0.015):
        self.level = level

    def __call__(self, chunk: np.ndarray) -> float:
        rms = float(np.sqrt(np.mean((chunk.astype(np.float32) / 32768.0) ** 2)))
        return min(1.0, rms / (self.level * 2))

    def reset(self) -> None:
        pass


class SileroVAD:
    """Silero VAD (small neural network, ~1 ms per 32 ms chunk, no PyTorch needed)."""

    def __init__(self):
        from pysilero_vad import SileroVoiceActivityDetector

        self._det = SileroVoiceActivityDetector()

    def __call__(self, chunk: np.ndarray) -> float:
        return float(self._det(chunk.astype(np.int16).tobytes()))

    def reset(self) -> None:
        self._det.reset()


def make_vad():
    try:
        return SileroVAD(), "Silero"
    except Exception:  # pragma: no cover - depends on installation
        return EnergyVAD(), "Lautstärke (Silero fehlt)"


@dataclass
class TurnEvent:
    kind: str  # "start" or "end"
    audio: np.ndarray | None = None  # int16, only for "end"


class TurnDetector:
    """Turns per-chunk speech probabilities into 'user started' / 'user finished' events.

    threshold      – probability above which a chunk counts as speech
    min_speech     – seconds of speech needed before we believe it (filters clicks)
    end_silence    – seconds of quiet after speech that end your turn
    pre_roll       – seconds of audio kept from before the start (so no syllable is lost)
    """

    def __init__(self, threshold: float = 0.5, min_speech: float = 0.25,
                 end_silence: float = 0.6, pre_roll: float = 0.3, max_turn: float = 30.0):
        self.threshold = threshold
        self.min_speech_chunks = max(1, round(min_speech / CHUNK_SEC))
        self.end_silence_chunks = max(1, round(end_silence / CHUNK_SEC))
        self.max_turn_chunks = round(max_turn / CHUNK_SEC)
        self._pre = deque(maxlen=max(1, round(pre_roll / CHUNK_SEC)))
        self.reset()

    def reset(self) -> None:
        self._pre.clear()
        self._audio: list[np.ndarray] = []
        self._speaking = False
        self._speech_run = 0
        self._silence_run = 0

    @property
    def in_speech(self) -> bool:
        return self._speaking

    def feed(self, prob: float, chunk: np.ndarray, threshold: float | None = None,
             min_speech_chunks: int | None = None) -> TurnEvent | None:
        thr = self.threshold if threshold is None else threshold
        need = self.min_speech_chunks if min_speech_chunks is None else min_speech_chunks
        is_speech = prob >= thr
        if not self._speaking:
            self._pre.append(chunk)
            self._speech_run = self._speech_run + 1 if is_speech else 0
            if self._speech_run >= need:
                self._speaking = True
                self._silence_run = 0
                self._audio = list(self._pre)
                self._pre.clear()
                return TurnEvent("start")
            return None

        self._audio.append(chunk)
        # Hysteresis: once speaking, a slightly lower probability still counts as speech.
        if prob >= thr - 0.15:
            self._silence_run = 0
        else:
            self._silence_run += 1
        if self._silence_run >= self.end_silence_chunks or len(self._audio) >= self.max_turn_chunks:
            keep = len(self._audio) - max(0, self._silence_run - 3)
            audio = np.concatenate(self._audio[:keep]) if self._audio else np.zeros(0, np.int16)
            self.reset()
            return TurnEvent("end", audio)
        return None
