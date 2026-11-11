"""The clipboard (wl-copy, else xclip), shared by live and recall.

wl-copy forks a background process that keeps serving the selection until something else is copied. That process must
not hold any pipe of ours (the caller would wait for it) and must not die with the popup window, so: stdout/stderr go
to /dev/null (nothing captured) and it starts in its own session (a closing terminal window hangs up its process group
only). Only stdin is a pipe; it is closed after the text, then we wait for the short-lived parent.

On GNOME, wl-copy needs keyboard focus on a Wayland window to own the clipboard. The live popup runs under XWayland
(so it can be kept on top) and holds the focus as an X11 window, so wl-copy can wait forever there. It gets a few
seconds; then the same text goes through xclip (an X11 client, which XWayland shares with Wayland apps) and xclip
also forks a background process that keeps serving it."""
from __future__ import annotations

import shutil
import subprocess

WL_TIMEOUT = 3          # wl-copy normally returns in milliseconds


def _run(cmd: list[str], text: str, timeout: float) -> None:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        p.communicate(text.encode(), timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        raise
    if p.returncode:
        raise subprocess.CalledProcessError(p.returncode, cmd[0])


def copy(text: str) -> None:
    try:
        _run(["wl-copy"], text, WL_TIMEOUT)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        if not shutil.which("xclip"):
            raise
        _run(["xclip", "-selection", "clipboard"], text, 10)
