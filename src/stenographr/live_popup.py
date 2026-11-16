"""The kitty popup and Ctrl+` (`live --toggle`): open, raise, keep on top, stop another recording instance, and where an instance runs."""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time

from . import registry
from .live import NAME
from .log import Log

TITLE = "stenographr live"                          # the popup window's title
WM_CLASS = "stenographr-live"                       # its window class: wmctrl -x finds it by this (a title could match a browser tab)


def detect_where(popup: bool) -> str:
    """Where this instance runs: 'popup', the tmux session name of its pane, or 'terminal'."""
    if popup:
        return "popup"
    if os.environ.get("TMUX"):
        pane = os.environ.get("TMUX_PANE")
        try:
            r = subprocess.run(["tmux", "display-message", "-p"] + (["-t", pane] if pane else []) + ["#{session_name}"],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return "terminal"


def toggle(cfg, log: Log, config_arg: str | None = None) -> int:
    """Ctrl+`. Only popups matter here; pane/terminal instances are never touched.
      a popup is recording -> stop it;  a popup exists otherwise (notice, cleaning, buttons) -> nothing;
      no popup (and none being launched) -> open a kitty window with one."""
    popups = [i for i in registry.instances() if i["kind"] == "popup"]
    if popups:
        if popups[0]["recording"]:
            os.kill(popups[0]["pid"], signal.SIGUSR1)
            log.info(NAME, f"stop requested (popup pid {popups[0]['pid']})")
        else:
            raise_popup(log)                       # buttons, notice, cleaning: bring it to the front with focus
        return 0
    if registry.launching_recently():
        return 0                                   # a popup is on its way up: never open a second one
    kitty = shutil.which("kitty")
    if not kitty:
        log.error(NAME, "kitty not found: cannot open the live window")
        return 1
    registry.mark_launching()
    cmd = [kitty, "--title", TITLE, "--class", WM_CLASS,
           "-o", "linux_display_server=x11",       # XWayland, popup only: wmctrl can then raise it / keep it on top
           "-o", "initial_window_width=80c", "-o", "initial_window_height=25c", "-o", "remember_window_size=no",
           sys.executable, "-m", "stenographr.cli"] + (["--config", config_arg] if config_arg else []) + ["live", "--popup"]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    _keep_on_top()
    log.info(NAME, "opened the live popup")
    return 0


def raise_popup(log: Log) -> None:
    """Bring the popup to the front and give it focus (wmctrl -a, by its window title)."""
    try:
        r = subprocess.run(["wmctrl", "-x", "-a", WM_CLASS], capture_output=True, text=True, timeout=5)
        log.info(NAME, "raised the popup" if r.returncode == 0
                 else f"could not raise the popup: {r.stderr.strip()[:100]}")
    except (OSError, subprocess.SubprocessError) as e:
        log.error(NAME, f"could not raise the popup: {type(e).__name__}: {e}")


def _keep_on_top() -> None:
    """Detached: once the popup's window exists, mark it always-on-top (gives up after ~10 s)."""
    sh = f'for i in $(seq 40); do wmctrl -x -r {WM_CLASS} -b add,above && exit 0; sleep 0.25; done'
    subprocess.Popen(["sh", "-c", sh], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def stop_other(entry: dict, timeout: float = 20.0) -> bool:
    """Tell the instance that is recording to stop (it moves to its own button step and stays open), and wait
    until it has let go of the microphone. Never closes or kills it."""
    try:
        os.kill(entry["pid"], signal.SIGUSR1)
    except OSError:
        return True
    t = time.time()
    while time.time() - t < timeout:
        cur = next((i for i in registry.instances() if i["pid"] == entry["pid"]), None)
        if cur is None or not cur["recording"]:
            return True
        time.sleep(0.1)
    return False
