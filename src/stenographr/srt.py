""".txt -> .srt (offsets into the video, not time of day)."""
from __future__ import annotations

import re
import os
from pathlib import Path

_LINE = re.compile(r"^\[(\d+):(\d\d):(\d\d) → (\d+):(\d\d):(\d\d) \| [^\]]*\] (.*)$")


def _ts(h: int, m: int, s: int) -> str:
    return f"{h:02d}:{m:02d}:{s:02d},000"


def txt_to_srt(text: str) -> str:
    blocks = []
    for line in text.splitlines():
        m = _LINE.match(line)
        if not m:
            continue
        h1, m1, s1, h2, m2, s2 = (int(x) for x in m.groups()[:6])
        a, b = h1 * 3600 + m1 * 60 + s1, h2 * 3600 + m2 * 60 + s2
        if b <= a:                                   # txt has whole seconds; SRT needs a nonzero span
            b = a + 1
        end = _ts(b // 3600, b % 3600 // 60, b % 60)
        blocks.append(f"{len(blocks) + 1}\n{_ts(h1, m1, s1)} --> {end}\n{m.group(7)}\n")
    return "\n".join(blocks)


def write_srt(txt_path: Path) -> Path:
    """FILE.srt next to FILE.txt. An existing FILE.srt is replaced atomically (temp file in the same folder, then rename)."""
    text = txt_to_srt(txt_path.read_text(encoding="utf-8"))
    out = txt_path.with_suffix(".srt")
    tmp = out.with_name(f".{out.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, out)
    finally:
        tmp.unlink(missing_ok=True)
    return out
