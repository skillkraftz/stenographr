"""The clipboard (wl-copy), shared by live and recall.

wl-copy forks a background process that keeps serving the selection until something else is copied. That process must
not hold any pipe of ours (the caller would wait for it) and must not die with the popup window, so: stdout/stderr go
to /dev/null (nothing captured) and it starts in its own session (a closing terminal window hangs up its process group
only). Only stdin is a pipe; it is closed after the text, then we wait for the short-lived parent."""
from __future__ import annotations

import subprocess


def copy(text: str) -> None:
    p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        p.communicate(text.encode(), timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        raise
    if p.returncode:
        raise subprocess.CalledProcessError(p.returncode, "wl-copy")
