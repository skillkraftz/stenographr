"""Test engine: no model (FAKE_ENGINE_COUNT=file logs one line per construction). One segment per FAKE_ENGINE_SECONDS of audio, text from FAKE_ENGINE_TEXT."""
from __future__ import annotations

import os

import numpy as np

from ..config import Config

SR = 16000


class FakeEngine:
    name = "fake"

    def __init__(self, cfg: Config, device: str):
        if os.environ.get("FAKE_ENGINE_COUNT"):          # tests count constructions (= model loads)
            with open(os.environ["FAKE_ENGINE_COUNT"], "a") as f:
                f.write(device + "\n")
        if device == "gpu" and os.environ.get("FAKE_ENGINE_FAIL_GPU") == "1":
            raise RuntimeError("fake CUDA failure")
        self.device = device

    def transcribe(self, audio: np.ndarray) -> list[dict]:
        step = float(os.environ.get("FAKE_ENGINE_SECONDS", "5"))
        total = len(audio) / SR
        words = os.environ.get("FAKE_ENGINE_TEXT", "hello world|second line").split("|")
        out, t, i = [], 0.0, 0
        while t < total:
            out.append({"start": t, "end": min(t + step, total), "text": words[i % len(words)]})
            t, i = t + step, i + 1
        return out
