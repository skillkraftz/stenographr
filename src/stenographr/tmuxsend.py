"""Find a Claude Code pane in tmux and type text into its input box. Uses the tmux command directly (no hyperbeam).

A Claude pane is one whose `pane_current_command` is `claude` (the same rule hyperbeam uses). Text goes in with
`tmux send-keys -l`, which appends to what is already in the input and never submits: this module never sends Enter.
"""
from __future__ import annotations

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


def attached_sessions() -> list[str]:
    """The sessions the attached tmux clients are looking at (each once)."""
    try:
        r = _tmux("list-clients", "-F", "#{client_session}")
    except (OSError, subprocess.SubprocessError):
        return []
    seen: list[str] = []
    for s in (r.stdout.splitlines() if r.returncode == 0 else []):
        if s and s not in seen:
            seen.append(s)
    return seen


def choose_target() -> tuple[str | None, dict[str, str]]:
    """(the unambiguous target session or None, all sessions with a Claude pane).
    Unambiguous = exactly one attached client and its session has a Claude pane. Otherwise the caller offers the
    list; with no Claude pane anywhere the list is empty and sending is not possible."""
    panes = claude_panes()
    clients = attached_sessions()
    if len(clients) == 1 and clients[0] in panes:
        return clients[0], panes
    return None, panes


def send(pane: str, text: str) -> None:
    """Type `text`, as one line, into the pane's input. Never presses Enter."""
    line = " ".join(text.split())
    r = _tmux("send-keys", "-t", pane, "-l", "--", line)
    if r.returncode != 0:
        raise RuntimeError(f"tmux send-keys failed: {r.stderr.strip()[:200]}")
