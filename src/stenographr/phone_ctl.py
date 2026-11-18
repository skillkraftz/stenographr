"""Setting up `stenographr phone`: the opt-in systemd user service and `tailscale serve` (tailnet only, never Funnel)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

UNIT = "stenographr-phone.service"


def unit_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "systemd" / "user" / UNIT


def _systemctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True)


def install(config: str | None) -> int:
    exe = shutil.which("stenographr")
    if not exe:
        print("stenographr: not on PATH, cannot build the service command", file=sys.stderr)
        return 1
    cfg = f" --config {os.path.abspath(config)}" if config else ""
    p = unit_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        "[Unit]\nDescription=stenographr phone notes (listens on 127.0.0.1 only)\n\n"
        f"[Service]\nExecStart={os.path.abspath(exe)}{cfg} phone\nRestart=on-failure\nRestartSec=10\n"
        "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin\n\n"
        "[Install]\nWantedBy=default.target\n", encoding="utf-8")
    for args in (("daemon-reload",), ("enable", "--now", UNIT)):
        r = _systemctl(*args)
        if r.returncode != 0:
            print(f"stenographr: systemctl --user {' '.join(args)} failed: {(r.stderr or r.stdout).strip()}", file=sys.stderr)
            return 1
    print(f"installed and started {UNIT} ({p}); `stenographr phone --remove` undoes it")
    return 0


def remove() -> int:
    p = unit_path()
    if not p.exists():
        print("not installed")
        return 0
    _systemctl("disable", "--now", UNIT)
    p.unlink()
    _systemctl("daemon-reload")
    print(f"removed {UNIT}")
    return 0


def _phone_url() -> str | None:
    try:
        r = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=10)
        return "https://" + json.loads(r.stdout)["Self"]["DNSName"].rstrip(".") + "/"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return None


def tailscale(mode: str, port: int) -> int:
    """`on`: tailscale serve --bg --https=443 http://127.0.0.1:<port> (tailnet only); `off`: undo it."""
    if not shutil.which("tailscale"):
        print("stenographr: tailscale is not installed", file=sys.stderr)
        return 1
    cmd = (["tailscale", "serve", "--https=443", "off"] if mode == "off"
           else ["tailscale", "serve", "--bg", "--https=443", f"http://127.0.0.1:{port}"])
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stderr + r.stdout).strip()
    if r.returncode != 0:
        if "access denied" in out.lower() or "operator" in out.lower() or "permission" in out.lower():
            print("stenographr: tailscale needs operator rights for this user. Run, then try again:\n"
                  "  sudo tailscale set --operator=$USER", file=sys.stderr)
        else:
            print(f"stenographr: {' '.join(cmd)} failed: {out}", file=sys.stderr)
        return 1
    if mode == "off":
        print("tailscale serve is off")
    else:
        print(f"on the phone (tailnet only): {_phone_url() or 'see `tailscale serve status`'}")
    return 0
