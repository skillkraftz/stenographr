"""Defaults, overridable in ~/.config/stenographr/config.toml (or $STENOGRAPHR_CONFIG)."""
from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field, fields
from pathlib import Path

DEFAULT_PATH = Path.home() / ".config" / "stenographr" / "config.toml"

# Kdenlive renders by running `kdenlive_render`, which execs `melt` (Debian/Ubuntu install it as
# melt -> melt-7, so either comm can show up). Kdenlive's own comm is deliberately not listed:
# the editor sitting open is not a render.
DEFAULT_BUSY = ["melt", "melt-7", "kdenlive_render"]


@dataclass
class Config:
    # [paths]
    models: Path = Path.home() / ".local" / "share" / "stenographr" / "models"
    archive: Path = Path("/data/transcripts")
    # [engine]
    engine: str = "parakeet-tdt-0.6b-v2-int8"
    num_threads: int = 8          # CPU threads for ONNX
    batch_size: int = 0           # VAD segments decoded at once; 0 = auto (GPU 1: batches OOM a 4 GB card, CPU 8)
    # [dictation]
    mic: str = "scarlett-mic"     # PipeWire node name; never falls back to another input
    channel: int = 1              # 1 = AUX0 (the voice); AUX1 is silent
    # [device]
    device: str = "auto"
    vram_need_mib: int = 1000     # measured peak ~0.7 GB (int8 Parakeet, batch 1) incl. CUDA context
    vram_margin_mib: int = 500
    max_gpu_util_pct: int = 30
    busy_processes: list[str] = field(default_factory=lambda: list(DEFAULT_BUSY))


_SECTIONS = {
    "paths": {"models", "archive"},
    "engine": {"engine", "num_threads", "batch_size"},
    "dictation": {"mic", "channel"},
    "device": {"device", "vram_need_mib", "vram_margin_mib", "max_gpu_util_pct", "busy_processes"},
}


def load(path: str | os.PathLike | None = None) -> Config:
    p = Path(path or os.environ.get("STENOGRAPHR_CONFIG") or DEFAULT_PATH)
    cfg = Config()
    if not p.exists():
        return cfg
    data = tomllib.loads(p.read_text())
    known = {f.name: f for f in fields(Config)}
    for section, keys in data.items():
        if not isinstance(keys, dict):
            raise ValueError(f"{p}: [{section}] must be a table")
        for k, v in keys.items():
            if k == "name" and section == "engine":
                k = "engine"
            if k not in known:
                raise ValueError(f"{p}: unknown key [{section}] {k}")
            if k in ("models", "archive"):
                v = Path(os.path.expanduser(v))
            setattr(cfg, k, v)
    return cfg
