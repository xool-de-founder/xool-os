"""Wake word "Hey Jarvis" with openWakeWord (Apache-2.0, runs locally on the CPU). Optional."""

from __future__ import annotations

import numpy as np

FRAME = 1280  # 80 ms at 16 kHz, what openWakeWord wants


class WakeWord:
    name = "openWakeWord"

    def __init__(self, threshold: float = 0.5):
        from openwakeword.model import Model
        from openwakeword.utils import download_models

        try:
            self.model = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")
        except Exception:
            download_models(["hey_jarvis"])
            self.model = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")
        self.threshold = threshold
        self._buf = np.zeros(0, np.int16)

    def reset(self) -> None:
        self._buf = np.zeros(0, np.int16)
        try:
            self.model.reset()
        except Exception:
            pass

    def feed(self, chunk: np.ndarray) -> bool:
        """True when the wake word was heard in what has come in so far."""
        self._buf = np.concatenate([self._buf, chunk.astype(np.int16)])
        hit = False
        while len(self._buf) >= FRAME:
            frame, self._buf = self._buf[:FRAME], self._buf[FRAME:]
            scores = self.model.predict(frame)
            if scores and max(scores.values()) >= self.threshold:
                hit = True
        return hit
