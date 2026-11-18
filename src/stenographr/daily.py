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


def start_line(start: dt.datetime, mode: str, where: str, audio: str | None = None) -> str:
    """`start: ... · mode · where[ · audio]` with its newline (`audio`: see Session)."""
    tail = f"{_SEP}{audio}" if audio else ""
    return f"start: {stamp(start)}{_SEP}{mode}{_SEP}{where}{tail}\n"


def end_line(when: dt.datetime, seconds: float, status: str) -> str:
    return f"end: {stamp(when)}{_SEP}{fmt_dur(seconds)}{_SEP}{status}\n"


def block_text(start: dt.datetime, mode: str, where: str, audio: str, lines: list[tuple[dt.datetime, str]],
               seconds: float, status: str) -> str:
    """One whole session block, for a single append_line (nothing from another writer can land inside it)."""
    out = [start_line(start, mode, where, audio)]
    out += [f"[{when:%H:%M:%S}] {' '.join(text.split())}\n" for when, text in lines]
    out.append(end_line(start + dt.timedelta(seconds=seconds), seconds, status))
    return "".join(out)


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
        self._write(start_line(start, mode, where, audio), first=True)

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
        self._write(end_line(when, (when - self.start).total_seconds(), status))


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
    """Sessions in start order. A session's text is its lines up to its end line, or, if that is missing,
    up to the next start line or the end of the file. Pointer lines are skipped. A `phone` block is written in one
    piece, so it can land inside a laptop session that is still open: it is read as its own session and the open
    one goes on after it."""
    out: list[Parsed | None] = []
    cur: dict | None = None
    outer: list[dict] = []                               # sessions a phone block landed in

    def close(c: dict):
        live = " ".join(c["lines"]).strip()
        clean = " ".join(c["clean"]).strip()
        out[c["slot"]] = Parsed(c["mode"], c["where"], clean or live, c["status"], day, c["hhmm"], c["audio"], live, clean)

    for line in text.splitlines():
        m = _START.match(line)
        if m:
            if cur is not None and m.group(2) == "phone" and cur["mode"] != "phone":
                outer.append(cur)
            else:
                for c in [cur, *reversed(outer)]:
                    if c:
                        close(c)
                outer = []
            out.append(None)
            cur = {"hhmm": m.group(1), "mode": m.group(2), "where": m.group(3), "audio": m.group(4) or "",
                   "lines": [], "clean": [], "in_clean": False, "status": None, "slot": len(out) - 1}
        elif cur is not None and _END.match(line):
            cur["status"] = _END.match(line).group(1)
            close(cur)
            cur = outer.pop() if outer else None
        elif _POINTER.match(line):
            pass                                         # `clip` appended it while this block was open: not part of it
        elif cur is not None and line.strip() == "clean:":
            cur["in_clean"] = True                       # what follows is the cleaned-up text; recall prefers it
        elif cur is not None and line.strip():
            cur["clean" if cur["in_clean"] else "lines"].append(_STAMP.sub("", line.strip()))
    for c in [cur, *reversed(outer)]:
        if c:
            close(c)
    return [p for p in out if p]
