"""The microphone: check the PipeWire node exists, start pw-record on it, pick channel 1."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import numpy as np

SR = 16000
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
    """Raw interleaved float32, 16 kHz, 2 channels, to `target` (a file, or '-' for stdout). --raw = no header."""
    return ["pw-record", "--target", mic, "--rate", str(SR), "--channels", str(CHANNELS), "--format", "f32",
            "--raw", target]


def channel_of(raw: bytes, channel: int) -> np.ndarray:
    """Mono float32 from interleaved stereo; channel is 1-based (1 = AUX0)."""
    n = len(raw) // (4 * CHANNELS) * (4 * CHANNELS)
    a = np.frombuffer(raw[:n], dtype=np.float32).reshape(-1, CHANNELS)
    return np.ascontiguousarray(a[:, channel - 1])


def window_title() -> str:
    """The focused window's title. Not available on GNOME Wayland without an extension: Shell.Eval is
    disabled and Introspect.GetWindows is refused, so this is always 'unknown' (see SPEC.md)."""
    return "unknown"
