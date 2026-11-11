"""Session blocks in the daily file (<archive>/steno-YYYY-MM-DD.txt) and in a notes file.

  start: 2026-11-09 10:00:00 · live · <where> · audio/<file>.opus
  <text>
  end: 2026-11-09 10:00:42 · 42s · ok

Append only. Clip/other pointer lines live in the same file (written by `clip`); sessions never touch them, and
a pointer line that lands inside an open block does not end it (see parse_sessions). Every line is ONE write() call
(append_line), so lines from different writers never get mixed inside a line.
"""
from __future__ import annotations

import datetime as dt
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .log import Log

_SEP = " · "


def stamp(t: dt.datetime) -> str:
    return f"{t:%Y-%m-%d %H:%M:%S}"


def fmt_dur(seconds: float) -> str:
    s = max(0, int(seconds))
    h, m, sec = s // 3600, s % 3600 // 60, s % 60
    if h:
        return f"{h}h{m:02d}m{sec:02d}s"
    return f"{m}m{sec:02d}s" if m else f"{sec}s"


def append_line(path: Path, text: str) -> None:
    """Append `text` (one or more whole lines) with a single write() on an O_APPEND file."""
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        data = text.encode("utf-8")
        if os.write(fd, data) != len(data):
            raise OSError("short write")
    finally:
        os.close(fd)


def daily_path(archive: Path, day: dt.datetime) -> Path:
    return archive / f"steno-{day:%Y-%m-%d}.txt"


def ok(no_speech: bool = False) -> str:
    return "ok (no speech)" if no_speech else "ok"


def failed(reason: str) -> str:
    return f"FAILED: {reason}, see steno.log"


class Session:
    """Writes one session block to one or more files as it goes. `targets` is [(path, header or None)]; the
    header line is written only when the file is created. A target that cannot be written is logged and
    skipped, so one bad file never costs the other."""

    def __init__(self, log: Log, name: str, targets: list[tuple[Path, str | None]], start: dt.datetime,
                 mode: str, where: str, audio: str | None = None):
        """`audio`: 'audio/<file>.opus', or 'audio: none' when it could not be kept; None = no audio part."""
        self.log, self.name, self.targets, self.start = log, name, targets, start
        tail = f"{_SEP}{audio}" if audio else ""
        self._write(f"start: {stamp(start)}{_SEP}{mode}{_SEP}{where}{tail}\n", first=True)

    def _write(self, text: str, first: bool = False) -> None:
        for path, header in self.targets:
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                if first and header and not path.exists():
                    text_out = header + "\n" + text
                else:
                    text_out = text
                append_line(path, text_out)
            except OSError as e:
                self.log.error(self.name, f"could not write {path}: {type(e).__name__}: {e}")

    def line(self, text: str, when: dt.datetime | None = None) -> None:
        """One sentence. With `when`, the line starts with the time of day it was said: [HH:MM:SS]."""
        prefix = f"[{when:%H:%M:%S}] " if when else ""
        self._write(prefix + " ".join(text.split()) + "\n")

    def marker(self, text: str) -> None:
        """A bare label line such as `clean:`."""
        self._write(text + "\n")

    def end(self, when: dt.datetime, status: str) -> None:
        self._write(f"end: {stamp(when)}{_SEP}{fmt_dur((when - self.start).total_seconds())}{_SEP}{status}\n")


# ---- reading (recall)

@dataclass
class Parsed:
    mode: str
    where: str
    text: str
    status: str | None      # None: no end line (crash)
    day: str
    hhmm: str = ""          # time of day the session started
    audio: str = ""         # 'audio/<file>.opus', 'audio: none', or '' (older files)
    live: str = ""          # the live phrases (a `live` session also has a clean block)
    clean: str = ""         # the cleaned-up text after a `clean:` line, if there is one


_START = re.compile(r"^start: \S+ (\d\d:\d\d):\d\d · (\w+) · (.*?)(?: · (audio/\S+|audio: none))?$")
_STAMP = re.compile(r"^\[\d\d:\d\d:\d\d\] ")
_END = re.compile(r"^end: \S+ \S+ · \S+ · (.*)$")
_POINTER = re.compile(r"^(clip|other): ")


def parse_sessions(text: str, day: str = "") -> list[Parsed]:
    """Sessions in file order. A session's text is its lines up to its end line, or, if that is missing,
    up to the next start line or the end of the file. Pointer lines are skipped."""
    out: list[Parsed] = []
    cur: dict | None = None

    def close():
        nonlocal cur
        if cur:
            live = " ".join(cur["lines"]).strip()
            clean = " ".join(cur["clean"]).strip()
            out.append(Parsed(cur["mode"], cur["where"], clean or live, cur["status"], day, cur["hhmm"], cur["audio"],
                              live, clean))
        cur = None

    for line in text.splitlines():
        m = _START.match(line)
        if m:
            close()
            cur = {"hhmm": m.group(1), "mode": m.group(2), "where": m.group(3), "audio": m.group(4) or "",
                   "lines": [], "clean": [], "in_clean": False, "status": None}
        elif cur is not None and _END.match(line):
            cur["status"] = _END.match(line).group(1)
            close()
        elif _POINTER.match(line):
            pass                                         # `clip` appended it while this block was open: not part of it
        elif cur is not None and line.strip() == "clean:":
            cur["in_clean"] = True                       # what follows is the cleaned-up text; recall prefers it
        elif cur is not None and line.strip():
            cur["clean" if cur["in_clean"] else "lines"].append(_STAMP.sub("", line.strip()))
    close()
    return out
