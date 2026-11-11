"""Find a Claude Code pane in tmux and type text into its input box. Uses the tmux command directly (no hyperbeam).

A Claude pane is one whose `pane_current_command` is `claude` (the same rule hyperbeam uses). Text goes in with
`tmux send-keys -l`, which appends to what is already in the input. Two ways in (the only place Enter is ever sent):
  append  the text plus one trailing space; no Enter, so several takes can be appended
  send    the text, then `send-keys Enter` (the way hyperbeam's send_line does it): submits everything now in the input
"""
from __future__ import annotations

import os
import subprocess


def _tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=5)


def claude_panes() -> dict[str, str]:
    """{session name: pane id of its Claude pane} for every session that has one (the first, if several)."""
    try:
        r = _tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{pane_current_command}")
    except (OSError, subprocess.SubprocessError):
        return {}
    out: dict[str, str] = {}
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            p = line.split("\t")
            if len(p) == 3 and p[2] == "claude":
                out.setdefault(p[0], p[1])
    return out


def _all_panes() -> dict[str, str]:
    """{pane id: session name} for every tmux pane."""
    try:
        r = _tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{pane_current_command}")
    except (OSError, subprocess.SubprocessError):
        return {}
    out: dict[str, str] = {}
    for line in (r.stdout.splitlines() if r.returncode == 0 else []):
        p = line.split("\t")
        if len(p) == 3:
            out[p[1]] = p[0]
    return out


def hyperbeam_pane() -> str | None:
    """The pane id hyperbeam named as this project's Claude pane (HB_CLAUDE_PANE), or None when not in hyperbeam.
    1. our own environment; 2. else, inside tmux, the HB_CLAUDE_PANE of the session our pane is in."""
    pane = os.environ.get("HB_CLAUDE_PANE", "").strip()
    if pane:
        return pane
    mine = os.environ.get("TMUX_PANE")
    if not mine:
        return None
    try:
        r = _tmux("display-message", "-p", "-t", mine, "#{session_name}")
        sess = r.stdout.strip() if r.returncode == 0 else ""
        if not sess:
            return None
        r = _tmux("show-environment", "-t", sess, "HB_CLAUDE_PANE")
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip() if r.returncode == 0 else ""
    return out.split("=", 1)[1].strip() or None if out.startswith("HB_CLAUDE_PANE=") else None


def choose_target() -> tuple[str | None, str | None, dict[str, str], str | None]:
    """(target session, target pane id, {session: Claude pane} for the picker, notice).
    A hyperbeam pane that exists is the target, no question (its session name is the target session). If the id is
    set but the pane is gone, the notice says so and the caller offers the picker. Not in hyperbeam: the picker."""
    panes = claude_panes()
    hb = hyperbeam_pane()
    if hb:
        sess = _all_panes().get(hb)
        if sess:
            return sess, hb, panes, None
        return None, None, panes, "hyperbeam's Claude pane not found"
    return None, None, panes, None


def send(pane: str, text: str, enter: bool = False) -> None:
    """Type `text`, as one line, into the pane's input. enter=False (append): add one trailing space and stop.
    enter=True (send): no trailing space, then press Enter once."""
    line = " ".join(text.split())
    if not enter:
        line += " "
    r = _tmux("send-keys", "-t", pane, "-l", "--", line)
    if r.returncode == 0 and enter:
        r = _tmux("send-keys", "-t", pane, "Enter")
    if r.returncode != 0:
        raise RuntimeError(f"tmux send-keys failed: {r.stderr.strip()[:200]}")
