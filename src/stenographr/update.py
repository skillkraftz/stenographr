"""`stenographr update`: show what is installed and pull the latest main into the editable checkout.

The tool is installed with `uv tool install --editable`, so the code that runs is this package's own checkout:
the source path is two folders above this file (src/stenographr/update.py -> the repo root), whatever the current
directory is. Never stashes, resets or switches branches; it only fast-forwards a clean main."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

SRC = Path(__file__).resolve().parents[2]


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(SRC), *args], capture_output=True, text=True)


def _out(*args: str) -> str:
    return _git(*args).stdout.strip()


def _commit() -> str:
    return _out("log", "-1", "--format=%h %s")


def _running_instances() -> list[str]:
    from . import registry                                  # numpy comes with it: only needed here
    out = []
    for i in registry.instances():
        age = int(time.time() - i.get("started", time.time()))
        out.append(f"  pid {i['pid']}  {i['kind']}  {i['where']}  (up {age // 60} min)")
    return out


def update() -> int:
    if not (SRC / "pyproject.toml").is_file() or _git("rev-parse", "--git-dir").returncode != 0:
        print(f"stenographr: {SRC} is not a git checkout: cannot update", file=sys.stderr)
        return 1
    branch = _out("rev-parse", "--abbrev-ref", "HEAD")
    print(f"source:  {SRC}")
    print(f"branch:  {branch}")
    print(f"commit:  {_commit()}")
    f = _git("fetch", "--quiet")
    if f.returncode != 0:
        print(f"stenographr: git fetch failed: {f.stderr.strip()}", file=sys.stderr)
        return 1
    ahead, behind = (int(x) for x in _out("rev-list", "--left-right", "--count", "HEAD...origin/main").split())
    print(f"origin:  {ahead} ahead, {behind} behind origin/main")
    if branch != "main":
        print(f"not updating: on branch {branch!r}, not main (switch by hand, this never changes branches)")
        return 1
    dirty = _out("status", "--porcelain")
    if dirty:
        print("not updating: uncommitted changes in the checkout (this never stashes or resets):")
        print("\n".join("  " + l for l in dirty.splitlines()[:10]))
        return 1

    updated = False
    if behind:
        old = _out("rev-parse", "HEAD")
        p = _git("pull", "--ff-only", "--quiet")
        if p.returncode != 0:
            print(f"stenographr: git pull --ff-only failed: {(p.stderr or p.stdout).strip()}", file=sys.stderr)
            return 1
        new = _out("rev-parse", "HEAD")
        print(f"pulled {behind} commit(s):")
        print("\n".join("  " + l for l in _out("log", "--format=%h %s", f"{old}..{new}").splitlines()))
        updated = True
        if "pyproject.toml" in _out("diff", "--name-only", old, new).splitlines():
            print("pyproject.toml changed: reinstalling (uv tool install --editable \".[gpu]\" --force)")
            r = subprocess.run(["uv", "tool", "install", "--editable", ".[gpu]", "--force"], cwd=SRC)
            if r.returncode != 0:
                print("stenographr: uv tool install failed (the checkout is updated, the install is not)", file=sys.stderr)
                return 1
        print(f"updated to {_commit()}")
    else:
        extra = f" (and {ahead} commit(s) ahead of origin, not pushed)" if ahead else ""
        print(f"up to date at {_commit().split()[0]}{extra}")

    running = _running_instances()
    if running:
        print("running live instances" + (" (restart them to run the new code; nothing was stopped):" if updated else ":"))
        print("\n".join(running))
    return 0
