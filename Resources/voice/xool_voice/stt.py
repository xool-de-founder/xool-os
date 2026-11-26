"""Speech to text with Whisper. On Apple Silicon we use MLX (runs on the GPU, very fast)."""

from __future__ import annotations

import platform
import sys

import numpy as np

DEFAULT_MLX_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_FW_MODEL = "large-v3-turbo"
PROMPT = "Hallo Jarvis. Das ist ein Gespräch auf Deutsch. Jarvis, such im Internet. Öffne die Seite."


def is_apple_silicon() -> bool:
    return sys.platform == "darwin" and platform.machine() == "arm64"


class MLXWhisper:
    name = "mlx-whisper"

    def __init__(self, model: str | None = None, language: str = "de"):
        import mlx_whisper

        self._mw = mlx_whisper
        self.model = model or DEFAULT_MLX_MODEL
        self.language = language

    def transcribe(self, audio16k: np.ndarray) -> str:
        audio = audio16k.astype(np.float32) / 32768.0
        out = self._mw.transcribe(
            audio,
            path_or_hf_repo=self.model,
            language=self.language,
            temperature=0.0,
            condition_on_previous_text=False,
            initial_prompt=PROMPT,
            no_speech_threshold=0.6,
            verbose=None,
        )
        return out.get("text", "").strip()


class FasterWhisper:
    name = "faster-whisper"

    def __init__(self, model: str | None = None, language: str = "de"):
        from faster_whisper import WhisperModel

        self.model = model or DEFAULT_FW_MODEL
        self.language = language
        self._m = WhisperModel(self.model, device="auto", compute_type="auto")

    def transcribe(self, audio16k: np.ndarray) -> str:
        audio = audio16k.astype(np.float32) / 32768.0
        segments, _ = self._m.transcribe(
            audio, language=self.language, beam_size=1, temperature=0.0,
            condition_on_previous_text=False, initial_prompt=PROMPT, vad_filter=False,
        )
        return " ".join(s.text.strip() for s in segments).strip()


def make_stt(model: str | None = None, language: str = "de"):
    if is_apple_silicon():
        try:
            return MLXWhisper(model, language)
        except ImportError:
            pass
    return FasterWhisper(model if model and "/" not in model else None, language)


def warmup(stt) -> None:
    """Run once on a short noise burst so the model is loaded and compiled."""
    rng = np.random.default_rng(0)
    stt.transcribe((rng.standard_normal(16000) * 50).astype(np.int16))
