""".md -> .srt (offsets into the video, not time of day)."""
from __future__ import annotations

import re
from pathlib import Path

from .clip import write_new

_LINE = re.compile(r"^\[(\d+):(\d\d):(\d\d) → (\d+):(\d\d):(\d\d) \| [^\]]*\] (.*)$")


def _ts(h: int, m: int, s: int) -> str:
    return f"{h:02d}:{m:02d}:{s:02d},000"


def md_to_srt(md_text: str) -> str:
    blocks = []
    for line in md_text.splitlines():
        m = _LINE.match(line)
        if not m:
            continue
        h1, m1, s1, h2, m2, s2 = (int(x) for x in m.groups()[:6])
        a, b = h1 * 3600 + m1 * 60 + s1, h2 * 3600 + m2 * 60 + s2
        if b <= a:                                   # md has whole seconds; SRT needs a nonzero span
            b = a + 1
        end = _ts(b // 3600, b % 3600 // 60, b % 60)
        blocks.append(f"{len(blocks) + 1}\n{_ts(h1, m1, s1)} --> {end}\n{m.group(7)}\n")
    return "\n".join(blocks)


def write_srt(md_path: Path) -> Path:
    """FILE.srt next to FILE.md; if it exists already, FILE-2.srt (never overwrites)."""
    text = md_to_srt(md_path.read_text(encoding="utf-8"))
    return write_new(md_path.parent, md_path.stem, ".srt", text)
