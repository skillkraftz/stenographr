"""The microphone: check the PipeWire node exists, start pw-record on it, pick channel 1."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import numpy as np

SR = 16000            # what the model/VAD wants
REC_RATE = 48000      # what we record at (decent voice quality for the kept audio)
CHANNELS = 2          # scarlett-mic is stereo (AUX0/AUX1); the voice is on AUX0, so we record both and keep one


def mic_exists(name: str) -> bool:
    """True if a PipeWire source node called `name` exists. Never falls back to another input."""
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=10, check=True).stdout
        for o in json.loads(out):
            p = (o.get("info") or {}).get("props") or {}
            if p.get("node.name") == name and str(p.get("media.class", "")).startswith("Audio/Source"):
                return True
    except (subprocess.SubprocessError, ValueError, OSError):
        pass
    return False


def recorder_cmd(mic: str, target: str) -> list[str]:
    """Raw interleaved float32, 48 kHz, 2 channels, to `target` (a file, or '-' for stdout). --raw = no header."""
    return ["pw-record", "--target", mic, "--rate", str(REC_RATE), "--channels", str(CHANNELS), "--format", "f32",
            "--raw", target]


def channel_of(raw: bytes, channel: int) -> np.ndarray:
    """Mono float32 from interleaved stereo; channel is 1-based (1 = AUX0)."""
    n = len(raw) // (4 * CHANNELS) * (4 * CHANNELS)
    a = np.frombuffer(raw[:n], dtype=np.float32).reshape(-1, CHANNELS)
    return np.ascontiguousarray(a[:, channel - 1])


class Down3:
    """48 kHz -> 16 kHz for the VAD/model: a low-pass (63-tap Kaiser-windowed sinc, cutoff 7.4 kHz), then keep
    every third sample. Stateful, so it can be fed chunks of any size. (No resampler library needed.)"""

    N = 63

    def __init__(self):
        k = np.arange(self.N) - (self.N - 1) / 2
        fc = 7400 / REC_RATE
        h = np.sinc(2 * fc * k) * 2 * fc * np.kaiser(self.N, 8.0)
        self.h = (h / h.sum()).astype(np.float32)
        self.tail = np.zeros(self.N - 1, dtype=np.float32)
        self.seen = 0                                    # filtered samples produced so far

    def __call__(self, x: np.ndarray) -> np.ndarray:
        buf = np.concatenate([self.tail, x.astype(np.float32, copy=False)])
        y = np.convolve(buf, self.h, mode="valid")       # one output per input sample
        self.tail = buf[-(self.N - 1):]
        out = y[(-self.seen) % 3::3]
        self.seen += len(y)
        return np.ascontiguousarray(out)
