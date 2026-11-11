"""Engine interface.

An engine turns 16 kHz mono float32 audio into segments [{start, end, text}] (seconds).
Which one is used comes from config (`engine`); add new ones by registering a factory here.
"""
from __future__ import annotations

import os
from typing import Callable, Protocol

import numpy as np

from ..config import Config

Segment = dict  # {"start": float, "end": float, "text": str}


class Engine(Protocol):
    name: str

    def transcribe(self, audio: np.ndarray) -> list[Segment]: ...

    def stream(self) -> "Streamer": ...

    def transcribe_long(self, audio: np.ndarray) -> list[Segment]:
        """One pass over a whole dictation session (16 kHz mono): segments that are whole sentences/paragraphs
        (unlike `stream`, which cuts at every short pause). Used for the clean text when a live session ends."""
        ...


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
}
if os.environ.get("STENOGRAPHR_TESTING") == "1":   # the fake engine exists only when the test script asks for it
    FACTORIES["fake"] = _fake


def gpu_runtime_available(engine: str) -> bool:
    if engine == "fake" and "fake" in FACTORIES:
        return os.environ.get("FAKE_ENGINE_GPU", "1") == "1"
    from .parakeet import gpu_runtime_available as g
    return g()


def make_engine(cfg: Config, device: str) -> Engine:
    try:
        f = FACTORIES[cfg.engine]
    except KeyError:
        raise ValueError(f"unknown engine {cfg.engine!r}; known: {', '.join(sorted(FACTORIES))}")
    return f(cfg, device)
