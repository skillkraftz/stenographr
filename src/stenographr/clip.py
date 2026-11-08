"""Video -> audio -> segments -> .md (+ archive copy)."""
from __future__ import annotations

import datetime as dt
import os
import re
import subprocess
from pathlib import Path

import numpy as np

SR = 16000
# Samsung camera names: YYYYMMDD_HHMMSS, optionally followed by a suffix (20261108_063820_1.mp4)
_SAMSUNG = re.compile(r"^(\d{8})_(\d{6})(?!\d)")


def recording_start(video: Path, recorded_at: str | None) -> tuple[dt.datetime, str]:
    """Samsung file name, else --recorded-at, else mtime. Returns (time, which one won)."""
    m = _SAMSUNG.match(video.name)
    if m:
        try:
            return dt.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S"), "file name"
        except ValueError:
            pass                      # looks like one but isn't a real date: keep falling back
    if recorded_at:
        s = recorded_at.strip().replace("T", " ")
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
            try:
                return dt.datetime.strptime(s, fmt), "--recorded-at"
            except ValueError:
                pass
        raise ValueError(f"cannot parse --recorded-at {recorded_at!r} (use 'YYYY-MM-DD HH:MM[:SS]')")
    return dt.datetime.fromtimestamp(video.stat().st_mtime).replace(microsecond=0), "file mtime"


def probe_duration(video: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(video)],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        raise RuntimeError(f"ffprobe could not read {video.name}: {out.stderr.strip()[:300]}")


def has_audio(video: Path) -> bool:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0",
         str(video)], capture_output=True, text=True)
    return bool(out.stdout.strip())


def extract_audio(video: Path) -> np.ndarray:
    """16 kHz mono float32, straight from ffmpeg's pipe (no temp file)."""
    p = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", str(SR),
         "-f", "f32le", "-"], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"ffmpeg failed ({p.returncode}): {p.stderr.decode(errors='replace').strip()[:300]}")
    if not p.stdout:
        raise RuntimeError("ffmpeg produced no audio (video has no audio stream?)")
    return np.frombuffer(p.stdout, dtype=np.float32)


def hms(seconds: float) -> str:
    s = int(seconds)                  # floor
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def time_of_day(start: dt.datetime, offset: float) -> str:
    return (start + dt.timedelta(seconds=int(offset))).strftime("%H:%M:%S")


def render_md(video: Path, start: dt.datetime, duration: float, engine: str, device: str,
              segments: list[dict], now: dt.datetime, note: str | None = None) -> str:
    lines = [
        f"# {video.stem} · recorded {start:%Y-%m-%d %H:%M} · {hms(duration)}",
        f"source: {video}",
        f"engine: {engine} ({device}) · transcribed {now:%Y-%m-%d %H:%M}",
        "",
    ]
    if note:                          # e.g. "(no audio)": still a transcript, so callers don't retry forever
        lines.append(note)
    for s in segments:
        lines.append(f"[{hms(s['start'])} → {hms(s['end'])} | {time_of_day(start, s['start'])}] {s['text']}")
    return "\n".join(lines) + "\n"


def write_new(directory: Path, stem: str, suffix: str, text: str) -> Path:
    """(srt only) Create directory/stem.suffix, or stem-2.suffix, stem-3.suffix... Never overwrites
    (exclusive create, so it is safe even against a concurrent writer)."""
    directory.mkdir(parents=True, exist_ok=True)
    n = 1
    while True:
        path = directory / (f"{stem}{suffix}" if n == 1 else f"{stem}-{n}{suffix}")
        try:
            with open(path, "x", encoding="utf-8") as f:
                f.write(text)
            return path
        except FileExistsError:
            n += 1


def write_exclusive(path: Path, text: str) -> None:
    """Create path or fail (FileExistsError): a transcript exists at most once per source file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "x", encoding="utf-8") as f:
        f.write(text)


def archive_name(video: Path, start: dt.datetime, how: str) -> str:
    """Flat archive file name: clip-<recording start><suffix>.md. For a Samsung name the suffix is whatever
    follows the timestamp (so 20251127_155055_001 stays distinct); otherwise "-" + the full stem."""
    suffix = video.stem[15:] if how == "file name" else "-" + video.stem
    return f"clip-{start:%Y-%m-%d-%H%M%S}{suffix}.md"
