"""Engine interface.

An engine turns 16 kHz mono float32 audio into segments [{start, end, text}] (seconds).
Which one is used comes from config (`engine`); add new ones by registering a factory here.
"""
from __future__ import annotations

from typing import Callable, Protocol

import numpy as np

from ..config import Config

Segment = dict  # {"start": float, "end": float, "text": str}


class Engine(Protocol):
    name: str

    def transcribe(self, audio: np.ndarray) -> list[Segment]: ...

    def stream(self) -> "Streamer": ...


class Streamer(Protocol):
    """Live audio in (16 kHz mono float32, any chunk size); finished, transcribed segments out as soon
    as the speaker pauses. flush() returns whatever is still pending."""

    def accept(self, audio: np.ndarray) -> list[Segment]: ...

    def flush(self) -> list[Segment]: ...


def _parakeet(cfg: Config, device: str) -> Engine:
    from .parakeet import ParakeetEngine
    return ParakeetEngine(cfg, device)


def _fake(cfg: Config, device: str) -> Engine:
    from .fake import FakeEngine
    return FakeEngine(cfg, device)


FACTORIES: dict[str, Callable[[Config, str], Engine]] = {
    "parakeet-tdt-0.6b-v2-int8": _parakeet,
    "fake": _fake,                       # tests only
}


def gpu_runtime_available(engine: str) -> bool:
    if engine == "fake":
        import os
        return os.environ.get("FAKE_ENGINE_GPU", "1") == "1"
    from .parakeet import gpu_runtime_available as g
    return g()


def make_engine(cfg: Config, device: str) -> Engine:
    try:
        f = FACTORIES[cfg.engine]
    except KeyError:
        raise ValueError(f"unknown engine {cfg.engine!r}; known: {', '.join(sorted(FACTORIES))}")
    return f(cfg, device)
