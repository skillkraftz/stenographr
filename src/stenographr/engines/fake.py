"""Test engine: no model (FAKE_ENGINE_COUNT=file logs one line per construction). One segment per FAKE_ENGINE_SECONDS of audio, text from FAKE_ENGINE_TEXT."""
from __future__ import annotations

import os
import time

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
        time.sleep(float(os.environ.get("FAKE_ENGINE_LOAD_DELAY", "0")))     # a slow model load
        if os.environ.get("FAKE_ENGINE_FAIL") == "1":    # the model cannot be loaded at all (after the delay)
            raise RuntimeError("fake model load failure")
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

    def stream(self):
        return FakeStream()

    def transcribe_long(self, audio: np.ndarray) -> list[dict]:
        """The 'clean pass': one segment per FAKE_ENGINE_CLEAN_SECONDS (15) of audio, texts from FAKE_ENGINE_CLEAN_TEXT.
        FAKE_ENGINE_CLEAN_FAIL=1: raise (to test the failure path)."""
        if os.environ.get("FAKE_ENGINE_CLEAN_FAIL") == "1":
            raise RuntimeError("fake clean-pass failure")
        time.sleep(float(os.environ.get("FAKE_ENGINE_CLEAN_DELAY", "0")))        # a slow clean pass
        step = float(os.environ.get("FAKE_ENGINE_CLEAN_SECONDS", "15"))
        words = os.environ.get("FAKE_ENGINE_CLEAN_TEXT", "Clean sentence one.|Clean sentence two.").split("|")
        seq = os.environ.get("FAKE_ENGINE_CLEAN_SEQ")                # a file: each clean pass takes its first line as its text
        if seq and os.path.exists(seq):
            lines = open(seq).read().splitlines()
            if lines:
                words = [lines[0]]
                open(seq, "w").write("\n".join(lines[1:]) + ("\n" if lines[1:] else ""))
        total = len(audio) / SR
        out, t, i = [], 0.0, 0
        while t < total:
            out.append({"start": t, "end": min(t + step, total), "text": words[i % len(words)]})
            t, i = t + step, i + 1
        for o in out:                                    # "{secs}" = how much audio the pass was given (proves what it ran on)
            o["text"] = o["text"].replace("{secs}", str(round(total)))
        return out


class FakeStream:
    """One segment per FAKE_ENGINE_SECONDS of audio fed; flush() emits a remainder longer than 0.5 s."""

    def __init__(self):
        self.step = float(os.environ.get("FAKE_ENGINE_SECONDS", "5"))
        self.words = os.environ.get("FAKE_ENGINE_TEXT", "hello world|second line").split("|")
        self.have = 0          # samples fed and not yet emitted
        self.t = 0.0
        self.i = 0

    def _emit(self, seconds: float) -> dict:
        seg = {"start": self.t, "end": self.t + seconds, "text": self.words[self.i % len(self.words)]}
        self.t += seconds
        self.i += 1
        return seg

    def accept(self, audio: np.ndarray) -> list[dict]:
        self.have += len(audio)
        out = []
        while self.have >= self.step * SR:
            self.have -= int(self.step * SR)
            out.append(self._emit(self.step))
        return out

    def flush(self) -> list[dict]:
        out = [self._emit(self.have / SR)] if self.have > 0.5 * SR else []
        self.have = 0
        return out
