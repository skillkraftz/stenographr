"""The GNOME custom keybinding for `stenographr live --toggle`. Only ever touches its own entry."""
from __future__ import annotations

import ast
import subprocess

NAME = "stenographr dictation"
BINDING = "<Control>grave"
SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
KEY = "custom-keybindings"
BASE = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"


def _gs(*args: str) -> str:
    return subprocess.run(["gsettings", *args], capture_output=True, text=True, check=True).stdout.strip()


def _list() -> list[str]:
    raw = _gs("get", SCHEMA, KEY)
    return list(ast.literal_eval(raw.removeprefix("@as ")))


def _set_list(paths: list[str]) -> None:
    _gs("set", SCHEMA, KEY, "[" + ", ".join(repr(p) for p in paths) + "]")


def _entry(path: str) -> str:
    return f"{SCHEMA}.custom-keybinding:{path}"


def _name(path: str) -> str:
    return ast.literal_eval(_gs("get", _entry(path), "name"))


def install(command: str) -> str:
    """Add (or update) the entry; returns its path. Existing entries stay as they are."""
    paths = _list()
    mine = next((p for p in paths if _name(p) == NAME), None)
    if mine is None:
        i = 0
        while f"{BASE}custom{i}/" in paths:
            i += 1
        mine = f"{BASE}custom{i}/"
    _gs("set", _entry(mine), "name", repr(NAME))
    _gs("set", _entry(mine), "command", repr(command))
    _gs("set", _entry(mine), "binding", repr(BINDING))
    if mine not in paths:
        _set_list(paths + [mine])
    return mine


def remove() -> bool:
    paths = _list()
    mine = [p for p in paths if _name(p) == NAME]
    for p in mine:
        _set_list([q for q in _list() if q != p])
        for k in ("name", "command", "binding"):
            _gs("reset", _entry(p), k)
    return bool(mine)
