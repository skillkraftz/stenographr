"""Which `stenographr live` instances are open, and is one of them recording.

Each instance writes `<runtime state dir>/live/<pid>.json` = {pid, kind: popup|loop, where, recording, started}.
Entries whose process is gone are ignored and removed when the registry is read. `toggle` only ever looks at
popups; an instance that wants to record looks for any other instance that is recording.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

from .dictate import _state_dir

LAUNCH_GRACE = 10.0          # seconds a just-launched popup has to register before another Ctrl+` may open one


def reg_dir() -> Path:
    return _state_dir() / "live"


def pid_alive(pid: int) -> bool:
    """Still a `stenographr ... live` process? (a reused pid or a zombie doesn't count)"""
    try:
        args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return any(b"stenographr" in a for a in args) and b"live" in args and b"--toggle" not in args and state != "Z"


class Entry:
    """This process's registry entry."""

    def __init__(self, kind: str, where: str):
        self.path = reg_dir() / f"{os.getpid()}.json"
        self.data = {"pid": os.getpid(), "kind": kind, "where": where, "recording": False, "started": time.time()}
        reg_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
        self._write()
        (reg_dir() / "popup.launching").unlink(missing_ok=True)          # a popup that registered is no longer "launching"

    def _write(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data))
        os.replace(tmp, self.path)                                       # readers never see a half-written file

    def set_recording(self, on: bool) -> None:
        self.data["recording"] = on
        self._write()

    def remove(self) -> None:
        self.path.unlink(missing_ok=True)


def instances() -> list[dict]:
    """All live instances (including this one); stale entries are deleted on the way."""
    out = []
    for f in sorted(reg_dir().glob("*.json")) if reg_dir().exists() else []:
        try:
            d = json.loads(f.read_text())
            if pid_alive(int(d["pid"])):
                out.append(d)
                continue
        except (OSError, ValueError, KeyError):
            pass
        f.unlink(missing_ok=True)
    return out


def recording_elsewhere() -> dict | None:
    """Another instance (not this process) that is recording right now."""
    return next((i for i in instances() if i["recording"] and i["pid"] != os.getpid()), None)


def mark_launching() -> None:
    reg_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
    (reg_dir() / "popup.launching").write_text(str(time.time()))


def launching_recently() -> bool:
    try:
        return time.time() - float((reg_dir() / "popup.launching").read_text()) < LAUNCH_GRACE
    except (OSError, ValueError):
        return False
