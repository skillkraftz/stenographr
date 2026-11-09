"""`stenographr recall [N]`: get a recent dictation back out of the daily files. Read-only."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .daily import Parsed, parse_sessions

LIST_SIZE = 10
BLURB = 60


def recent_sessions(archive: Path, n: int) -> list[Parsed]:
    """Newest first: type and notes sessions (failed ones and ones with no end line included), not clip
    lines, not empty sessions. Reads earlier daily files until there are `n`."""
    out: list[Parsed] = []
    for f in sorted(archive.glob("steno-????-??-??.txt"), reverse=True):
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        sessions = [s for s in parse_sessions(text, f.stem[6:]) if s.text]
        out += reversed(sessions)
        if len(out) >= n:
            break
    return out[:n]


def blurb(text: str) -> str:
    return text if len(text) <= BLURB else text[:BLURB].rstrip() + "..."


def _copy(text: str) -> None:
    subprocess.run(["wl-copy"], input=text, text=True, timeout=10, check=True)


def recall(archive: Path, n: int | None, stdin=None) -> int:
    sessions = recent_sessions(archive, max(LIST_SIZE, n or 0))
    if not sessions:
        print("stenographr: nothing to recall", file=sys.stderr)
        return 1
    if n is None:
        for i, s in enumerate(sessions[:LIST_SIZE], 1):
            print(f"{i}. {blurb(s.text)}")
        try:
            answer = (stdin or sys.stdin).readline() if stdin else input("Which do you need to copy? ")
        except EOFError:
            return 0
        answer = answer.strip()
        if answer in ("", "q", "Q"):
            return 0
        try:
            n = int(answer)
        except ValueError:
            print(f"stenographr: not a number: {answer}", file=sys.stderr)
            return 1
    if not 1 <= n <= len(sessions):
        print(f"stenographr: no session {n} (have {len(sessions)})", file=sys.stderr)
        return 1
    text = sessions[n - 1].text
    try:
        _copy(text)
    except Exception as e:                               # noqa: BLE001
        print(f"stenographr: clipboard failed ({e}); the text is below", file=sys.stderr)
        print(text)
        return 1
    print("recalled:")
    print(text)
    return 0
