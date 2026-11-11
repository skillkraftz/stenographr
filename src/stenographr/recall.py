"""`stenographr recall [N]`: get a recent dictation back out of ONE daily file. Read-only on every file.

A piece is one session block (start..end, or start..EOF when the end line is missing) or one clip/other
line. Pieces are numbered newest first.
"""
from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from . import clipboard

from .daily import parse_sessions

SHOW = 10
BLURB = 60
_POINTER = re.compile(r"^(clip|other): \S+ (\d\d:\d\d):\d\d · (.+?) (?:→ (\S+)|· (.*))$")
_SEG = re.compile(r"^\[\d+:\d\d:\d\d → \d+:\d\d:\d\d \| \d\d:\d\d:\d\d\] (.*)$")


@dataclass
class Piece:
    kind: str                 # type | notes | clip | other
    hhmm: str
    text: str = ""            # sessions: their text. clip/other: filled from the transcript file
    source: str = ""          # clip/other: the source name
    rel: str = ""             # clip/other: transcript path relative to the archive ('' = none was written)
    note: str = ""            # clip/other without a transcript: what the line says (FAILED / refused)


def transcript_text(path: Path) -> str | None:
    """The spoken text of a clip transcript: no header, no time prefixes. None if the file is missing."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    return " ".join(m.group(1).strip() for m in map(_SEG.match, lines) if m)


def pieces_of(text: str, archive: Path) -> list[Piece]:
    """Pieces in file order. Sessions with no text (a failed start) are not pieces."""
    pieces: list[Piece] = []
    for chunk in _split(text):
        if isinstance(chunk, str):
            m = _POINTER.match(chunk)
            if not m:
                continue
            kind, hhmm, source, rel, note = m.groups()
            p = Piece(kind, hhmm, source=source, rel=rel or "", note=note or "")
            if rel:
                p.text = transcript_text(archive / rel) or ""
            pieces.append(p)
        elif chunk.text:
            pieces.append(Piece(chunk.mode, chunk.hhmm, chunk.text))
    return pieces


def _split(text: str):
    """Pointer lines as strings, sessions as Parsed, in file order."""
    out, buf = [], []
    for line in text.splitlines():
        if re.match(r"^(clip|other): ", line):
            if buf:
                out += parse_sessions("\n".join(buf))
                buf = []
            out.append(line)
        else:
            buf.append(line)
    if buf:
        out += parse_sessions("\n".join(buf))
    return out


def default_file(archive: Path) -> tuple[Path, list[Piece]] | None:
    """Today's daily file; if it has no pieces, the most recent daily file that does."""
    for f in sorted(archive.glob("steno-????-??-??.txt"), reverse=True):
        try:
            pieces = pieces_of(f.read_text(encoding="utf-8"), archive)
        except OSError:
            continue
        if pieces:
            return f, pieces
    return None


def blurb(text: str) -> str:
    return text if len(text) <= BLURB else text[:BLURB].rstrip() + "..."


def label(p: Piece) -> str:
    if p.kind in ("clip", "other"):
        body = blurb(p.text) if p.text else (p.note or "(no transcript)")
        return f"[{p.hhmm}] {p.kind} · {p.source} · {body}"
    return f"[{p.hhmm}] {p.kind} · {blurb(p.text)}"


_copy = clipboard.copy                                   # wl-copy, detached with no captured pipes (clipboard.py)


def _show(listed: list[Piece], total: int) -> None:
    for i, p in enumerate(listed, 1):                    # newest first: 1 is the last piece in the file
        print(f"{i}. {label(p)}")


def _choose(archive: Path, p: Piece) -> int:
    text = p.text
    if p.kind in ("clip", "other"):
        if not p.rel:
            print(f"stenographr: no transcript for this line ({p.note}); nothing copied", file=sys.stderr)
            return 1
        t = transcript_text(archive / p.rel)
        if t is None:
            print(f"stenographr: transcript file is missing: {archive / p.rel}; nothing copied", file=sys.stderr)
            return 1
        text = t
    if not text:
        print("stenographr: no text in that piece; nothing copied", file=sys.stderr)
        return 1
    try:
        _copy(text)
    except Exception as e:                               # noqa: BLE001
        print(f"stenographr: clipboard failed ({e}); the text is below", file=sys.stderr)
        print(text)
        return 1
    print("recalled:")
    print(text)
    return 0


def recall(archive: Path, n: int | None) -> int:
    found = default_file(archive)
    if not found:
        print("stenographr: nothing to recall", file=sys.stderr)
        return 1
    path, pieces = found
    newest_first = list(reversed(pieces))
    total = len(newest_first)
    if n is not None:
        if not 1 <= n <= total:
            print(f"stenographr: no piece {n} in {path.name} (it has {total})", file=sys.stderr)
            return 1
        return _choose(archive, newest_first[n - 1])
    print(f"{path.name}: {total} piece{'s' if total != 1 else ''}")
    _show(newest_first[:SHOW], total)
    while True:
        try:
            answer = input("Which do you need to copy? (a = list all) ").strip()
        except EOFError:
            return 0
        if not sys.stdin.isatty():
            print()                                      # piped answers aren't echoed: end the prompt line
        if answer in ("", "q", "Q"):
            return 0
        if answer in ("a", "A"):
            _show(newest_first, total)
            continue
        try:
            k = int(answer)
        except ValueError:
            k = 0
        if not 1 <= k <= total:
            print(f"stenographr: choose 1 to {total}, a, or q", file=sys.stderr)
            continue
        return _choose(archive, newest_first[k - 1])
