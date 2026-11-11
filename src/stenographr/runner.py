"""Engine reuse and the CPU/GPU decision, shared by `clip`, `notes` and `live`."""
from __future__ import annotations

import threading
import time

from . import clip as clipmod
from . import device as devmod
from .engines import gpu_runtime_available, make_engine
from .log import Log


class Engines:
    """One engine per device per run: the model load is the slow part, so build lazily and reuse."""

    def __init__(self, cfg, log: Log):
        self.cfg, self.log = cfg, log
        self.built: dict[str, object] = {}
        self.failed: dict[str, Exception] = {}       # a device that could not be built stays failed for the run
        self._lock = threading.Lock()                # the live app preloads in a thread while a capture may ask too
        self.decided: str | None = None              # live/notes: the device is decided once (decide()); clip decides per file

    def decide(self, requested: str, name: str) -> str:
        """The device for the whole run: decided on the first call, reused after (so a capture never builds a second
        engine because the GPU got busy since the preload)."""
        with self._lock:
            if self.decided is None:
                self.decided = pick_device(self.cfg, self.log, name, requested)
            return self.decided

    def get(self, device: str, name: str):
        with self._lock:                             # built once; a second caller waits for the first to finish
            if device in self.failed:
                raise self.failed[device]
            if device not in self.built:
                t0 = time.monotonic()
                try:
                    self.built[device] = make_engine(self.cfg, device)
                except Exception as e:               # noqa: BLE001
                    self.failed[device] = e
                    raise
                self.log.info(name, f"engine loaded: device={device} load={time.monotonic() - t0:.2f}s")
            return self.built[device]


def pick_device(cfg, log: Log, name: str, requested: str) -> str:
    decision = devmod.decide(cfg, requested, gpu_runtime_available(cfg.engine))
    log.info(name, f"device: {decision.device} ({decision.reason})")
    return decision.device


def transcribe_audio(cfg, log: Log, engines: Engines, name: str, audio, requested: str, method: str = "transcribe"):
    """Whole-recording transcription. A failed GPU run is redone on the CPU. Returns (segments, device)."""
    device = engines.decided or pick_device(cfg, log, name, requested)
    segments = None
    while segments is None:
        try:
            engine = engines.get(device, name)
            t1 = time.monotonic()
            segments = getattr(engine, method)(audio)
        except Exception as e:                       # noqa: BLE001 - any engine failure
            if device == "gpu":
                log.error(name, f"GPU run failed, redoing on CPU: {type(e).__name__}: {e}")
                device = "cpu"
                continue
            raise
        t2 = time.monotonic()
    audio_s = len(audio) / clipmod.SR
    run = t2 - t1
    log.info(name, f"timing: device={device} audio={audio_s:.1f}s transcribe={run:.2f}s "
                   f"rtf={run / audio_s if audio_s else 0:.4f}")
    return segments, device
