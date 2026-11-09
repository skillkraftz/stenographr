"""Dictation. Two modes share one live loop (`_live`):

  notes  `stenographr notes`: sentences are printed in the terminal and appended to ./steno-DATE.txt + the daily file
  type   `stenographr toggle` (Ctrl+`): the first press starts a background session (`_type-session`) that types
         each sentence at the cursor as I pause; the second press (SIGTERM) finishes it.
"""
from __future__ import annotations

import datetime as dt
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import daily
from .log import Log
from .record import channel_of, mic_exists, recorder_cmd, window_title
from .runner import Engines, pick_device


# ---------------------------------------------------------------- shared

def _fail_block(cfg, log: Log, name: str, mode: str, where: str, start: dt.datetime, reason: str) -> None:
    """A session that never got going still leaves a block in the daily file: the failure shows there first."""
    s = daily.Session(log, name, [(daily.daily_path(cfg.archive, start), None)], start, mode, where)
    s.end(dt.datetime.now(), daily.failed(reason))


def _copy(text: str) -> None:
    # wl-copy forks to serve the selection, so don't capture its output (the pipe would stay open)
    subprocess.run(["wl-copy"], input=text, text=True, timeout=10, check=True)


def _type(text: str) -> None:
    subprocess.run(["ydotool", "type", "--file", "-"], input=text, text=True, capture_output=True,
                   timeout=120, check=True)


def _state_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/stenographr-{os.getuid()}"
    return Path(base) / "stenographr"


def _live(cfg, log: Log, requested: str, name: str, mode: str, where: str, targets, on_sentence,
          before_end=None, on_stop=None) -> tuple[str, list[str]]:
    """Record from the mic and turn speech into sentences as the speaker pauses.

    The recorder starts FIRST and a thread keeps reading it, so the audio spoken while the model loads is
    queued, not lost. Every sentence goes to the session files at once, as `[HH:MM:SS] text` (recording start
    + the sentence's offset into the audio), and to `on_sentence(text)` (no timestamp). SIGINT/SIGTERM
    finish the sentence in progress and end the session. `before_end(texts)` may return problems (e.g. the
    clipboard failed) that go into the end line. Returns (end status, sentences)."""
    t0 = dt.datetime.now()
    stop: list[int] = []

    def handler(*_):
        if not stop:
            stop.append(1)
            if on_stop:
                on_stop()

    for sig in (signal.SIGINT, signal.SIGTERM):          # also overrides SIGINT=ignored (background jobs)
        signal.signal(sig, handler)

    _state_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
    err = open(_state_dir() / f"{name}.err", "wb")
    proc = subprocess.Popen(recorder_cmd(cfg.mic, "-"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=err, start_new_session=True)
    q: queue.Queue = queue.Queue()

    def pump():
        fd = proc.stdout.fileno()
        while True:
            try:
                b = os.read(fd, 65536)
            except OSError:
                b = b""
            q.put(b or None)
            if not b:
                return

    threading.Thread(target=pump, daemon=True).start()
    sess = daily.Session(log, name, targets, t0, mode, where)
    log.info(name, f"start: {where}, mic {cfg.mic} channel {cfg.channel}")

    texts: list[str] = []
    status = daily.ok()

    def emit(segs):
        for s in segs:
            if not s["text"].strip():
                continue
            when = t0 + dt.timedelta(seconds=s["start"])
            sess.line(s["text"], when)
            texts.append(s["text"])
            on_sentence(s["text"])

    stream = None
    try:
        engines = Engines(cfg, log)
        device = pick_device(cfg, log, name, requested)
        try:
            stream = engines.get(device, name).stream()
        except Exception as e:                           # noqa: BLE001
            if device != "gpu":
                raise
            log.error(name, f"GPU engine failed, using CPU: {type(e).__name__}: {e}")
            stream = engines.get("cpu", name).stream()

        rest, stopping = b"", False
        while True:
            if stop and not stopping:
                stopping = True                          # no more audio: stop the recorder, drain what it sent
                try:
                    os.killpg(proc.pid, signal.SIGINT)
                except OSError:
                    pass
            try:
                b = q.get(timeout=0.2)
            except queue.Empty:
                if proc.poll() is not None and not stopping and q.empty():
                    log.error(name, f"pw-record exited unexpectedly (rc {proc.returncode})")
                    status = daily.failed("recorder exited")
                    break
                continue
            if b is None:                                # recorder's output closed
                if not stopping and not stop:
                    log.error(name, "pw-record closed its output unexpectedly")
                    status = daily.failed("recorder exited")
                break
            rest += b
            k = len(rest) // 8 * 8                       # whole stereo float32 frames only
            data, rest = rest[:k], rest[k:]
            emit(stream.accept(channel_of(data, cfg.channel)))
        emit(stream.flush())                             # the sentence still in progress
    except Exception as e:                               # noqa: BLE001
        log.error(name, f"{type(e).__name__}: {e}")
        status = daily.failed("engine failed" if stream is None else "transcription error")
    finally:
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    problems = before_end(texts) if before_end else []
    if status == daily.ok():
        status = daily.failed(", ".join(problems)) if problems else daily.ok(no_speech=not texts)
    sess.end(dt.datetime.now(), status)
    log.info(name, f"finish: {len(texts)} sentences, {status}")
    return status, texts


# ---------------------------------------------------------------- toggle (type mode)

def _read_state(d: Path) -> tuple[int, float] | None:
    try:
        pid, t0 = (d / "state").read_text().split()
        return int(pid), float(t0)
    except (OSError, ValueError):
        return None


def _is_session(pid: int) -> bool:
    """Is `pid` still our background type session? (a recycled pid, or a zombie, doesn't count)"""
    try:
        if b"_type-session" not in Path(f"/proc/{pid}/cmdline").read_bytes():
            return False
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def toggle(cfg, log: Log, requested: str, config_arg: str | None = None) -> int:
    """First press: start the background session and return at once. Second press: tell it to finish."""
    d = _state_dir()
    st = _read_state(d)
    if st and _is_session(st[0]):
        os.kill(st[0], signal.SIGTERM)                   # the session finishes the last sentence by itself
        log.info("type", f"stop requested (pid {st[0]})")
        return 0
    if st:
        log.warn("type", f"stale session state (pid {st[0]} is gone): starting a new session")
        (d / "state").unlink(missing_ok=True)
    now = dt.datetime.now()
    if not mic_exists(cfg.mic):
        log.error("type", f"mic {cfg.mic} not found: nothing recorded")
        _fail_block(cfg, log, "type", "type", window_title(), now, f"mic {cfg.mic} not found")
        return 1
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    cmd = [sys.executable, "-m", "stenographr.cli"] + (["--config", config_arg] if config_arg else []) \
        + ["_type-session", "--device", requested]
    with open(d / "session.err", "wb") as err:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err,
                                start_new_session=True)  # survives this process (no terminal needed)
    (d / "state").write_text(f"{proc.pid} {now.timestamp()}\n")
    log.info("type", f"start: session pid {proc.pid}")
    return 0


def type_session(cfg, log: Log, requested: str) -> int:
    """The background process behind `toggle`: types each sentence (plus a space) as it is spoken."""
    d = _state_dir()
    me = os.getpid()
    problems: set[str] = set()

    def forget():                                        # a third press during wrap-up must start fresh
        st = _read_state(d)
        if st and st[0] == me:
            (d / "state").unlink(missing_ok=True)

    def on_sentence(text: str) -> None:
        try:
            _type(text + " ")
        except Exception as e:                           # noqa: BLE001
            detail = getattr(e, "stderr", "") or ""
            log.error("type", f"typing (ydotool) failed: {type(e).__name__}: {e} {detail}")
            problems.add("typing failed")

    def before_end(texts: list[str]) -> list[str]:
        if texts:
            try:
                _copy(" ".join(texts))                   # the whole session, no timestamps
            except Exception as e:                       # noqa: BLE001
                log.error("type", f"clipboard (wl-copy) failed: {type(e).__name__}: {e}")
                problems.add("clipboard failed")
        return sorted(problems)

    start = dt.datetime.now()
    try:
        status, _ = _live(cfg, log, requested, "type", "type", window_title(),
                          [(daily.daily_path(cfg.archive, start), None)], on_sentence, before_end, on_stop=forget)
    finally:
        forget()
    return 0 if status.startswith("ok") else 1


# ---------------------------------------------------------------- notes

def _gitignore(log: Log) -> None:
    """Notes files must not get committed by accident: in a git work tree where steno-*.txt isn't ignored,
    append that pattern to the repo root's .gitignore. Never commits anything."""
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if top.returncode != 0:
            return
        if subprocess.run(["git", "check-ignore", "-q", "steno-test.txt"]).returncode != 1:
            return                                       # 0: already ignored; 128: git error: leave it alone
        gi = Path(top.stdout.strip()) / ".gitignore"
        old = gi.read_text() if gi.exists() else ""
        with open(gi, "a", encoding="utf-8") as f:
            f.write(("\n" if old and not old.endswith("\n") else "") + "steno-*.txt\n")
        log.info("notes", f"added steno-*.txt to {gi}")
    except (OSError, FileNotFoundError) as e:
        log.error("notes", f"could not update .gitignore: {type(e).__name__}: {e}")


def notes(cfg, log: Log, requested: str) -> int:
    start = dt.datetime.now()
    cwd = Path.cwd().absolute()
    name = "notes"
    if not mic_exists(cfg.mic):
        log.error(name, f"mic {cfg.mic} not found: nothing recorded")
        _fail_block(cfg, log, name, "notes", str(cwd), start, f"mic {cfg.mic} not found")
        print(f"stenographr: mic {cfg.mic} not found", file=sys.stderr)
        return 1
    _gitignore(log)
    notes_file = cwd / f"steno-{start:%Y-%m-%d}.txt"
    print(f"stenographr notes: listening on {cfg.mic}; Ctrl+C to stop", file=sys.stderr)
    status, _ = _live(cfg, log, requested, name, "notes", str(cwd),
                      [(daily.daily_path(cfg.archive, start), None),
                       (notes_file, f"stenographr notes · {cwd}")],
                      lambda text: print(text, flush=True))          # terminal: no timestamps
    return 0 if status.startswith("ok") else 1
