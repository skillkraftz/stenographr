"""Dictation: `toggle` (record, then type + clipboard + daily file) and `notes` (live, sentence by sentence)."""
from __future__ import annotations

import datetime as dt
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import daily
from .log import Log
from .record import SR, channel_of, mic_exists, recorder_cmd, window_title
from .runner import Engines, pick_device, transcribe_audio


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


# ---------------------------------------------------------------- toggle

def _state_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/stenographr-{os.getuid()}"
    return Path(base) / "stenographr"


def _read_state(d: Path) -> tuple[int, float] | None:
    try:
        pid, t0 = (d / "state").read_text().split()
        return int(pid), float(t0)
    except (OSError, ValueError):
        return None


def _is_recorder(pid: int) -> bool:
    """Is `pid` still our pw-record? (a recycled pid, or a zombie, doesn't count)"""
    try:
        if b"pw-record" not in Path(f"/proc/{pid}/cmdline").read_bytes():
            return False
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def toggle(cfg, log: Log, requested: str) -> int:
    d = _state_dir()
    st = _read_state(d)
    if st and _is_recorder(st[0]):
        return _stop(cfg, log, requested, d, *st)
    if st:
        log.warn("type", f"stale recorder state (pid {st[0]} is gone): starting a new recording")
        (d / "state").unlink(missing_ok=True)
    return _start(cfg, log, d)


def _start(cfg, log: Log, d: Path) -> int:
    now = dt.datetime.now()
    if not mic_exists(cfg.mic):
        log.error("type", f"mic {cfg.mic} not found: nothing recorded")
        _fail_block(cfg, log, "type", "type", window_title(), now, f"mic {cfg.mic} not found")
        return 1
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    audio = d / "rec.f32"
    audio.unlink(missing_ok=True)
    with open(d / "rec.err", "wb") as err:
        proc = subprocess.Popen(recorder_cmd(cfg.mic, str(audio)), stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=err, start_new_session=True)
    time.sleep(0.3)
    if proc.poll() is not None:
        detail = (d / "rec.err").read_text(errors="replace").strip()[:300]
        log.error("type", f"pw-record exited at start (rc {proc.returncode}): {detail}")
        _fail_block(cfg, log, "type", "type", window_title(), now, "recorder failed to start")
        return 1
    (d / "state").write_text(f"{proc.pid} {now.timestamp()}\n")
    log.info("type", f"start: recording from {cfg.mic} channel {cfg.channel} (pid {proc.pid})")
    return 0


def _stop(cfg, log: Log, requested: str, d: Path, pid: int, t0: float) -> int:
    stopped = dt.datetime.now()
    start = dt.datetime.fromtimestamp(t0)
    try:
        os.kill(pid, signal.SIGINT)
    except OSError:
        pass
    for _ in range(30):                                  # pw-record flushes its file on SIGINT
        if not _is_recorder(pid):
            break
        time.sleep(0.1)
    else:
        os.kill(pid, signal.SIGKILL)
        log.warn("type", f"pw-record (pid {pid}) did not stop on SIGINT: killed")
    (d / "state").unlink(missing_ok=True)

    name, where = "type", window_title()
    log.info(name, f"stop: recorded {(stopped - start).total_seconds():.1f}s")
    try:
        audio_file = d / "rec.f32"
        raw = audio_file.read_bytes() if audio_file.exists() else b""
        mono = channel_of(raw, cfg.channel)
        if len(mono) < 0.3 * SR:
            segments = []
        else:
            segments, _ = transcribe_audio(cfg, log, Engines(cfg, log), name, mono, requested)
        text = " ".join(s["text"] for s in segments).strip()
    except Exception as e:                               # noqa: BLE001
        log.error(name, f"transcription failed: {type(e).__name__}: {e}")
        _fail_block(cfg, log, name, "type", where, start, "transcription failed")
        return 1

    problems = []
    if text:
        try:
            _copy(text)
        except Exception as e:                           # noqa: BLE001
            log.error(name, f"clipboard (wl-copy) failed: {type(e).__name__}: {e}")
            problems.append("clipboard failed")
        try:
            _type(text)
        except Exception as e:                           # noqa: BLE001
            detail = getattr(e, "stderr", "") or ""
            log.error(name, f"typing (ydotool) failed: {type(e).__name__}: {e} {detail}")
            problems.append("typing failed")

    s = daily.Session(log, name, [(daily.daily_path(cfg.archive, start), None)], start, "type", where)
    if text:
        s.line(text)
    status = daily.failed(", ".join(problems)) if problems else daily.ok(no_speech=not text)
    s.end(stopped, status)
    log.info(name, f"finish: {len(text.split())} words, {status}")
    return 1 if problems else 0


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

    engines = Engines(cfg, log)
    device = pick_device(cfg, log, name, requested)
    try:
        stream = engines.get(device, name).stream()
    except Exception as e:                               # noqa: BLE001
        if device != "gpu":
            log.error(name, f"engine failed: {type(e).__name__}: {e}")
            _fail_block(cfg, log, name, "notes", str(cwd), start, "engine failed")
            print(f"stenographr: engine failed: {e}", file=sys.stderr)
            return 1
        log.error(name, f"GPU engine failed, using CPU: {type(e).__name__}: {e}")
        stream = engines.get("cpu", name).stream()

    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):          # also overrides SIGINT=ignored (background jobs)
        signal.signal(sig, lambda *_: stop.append(1))

    start = dt.datetime.now()                            # the clock starts when we are listening
    notes_file = cwd / f"steno-{start:%Y-%m-%d}.txt"
    sess = daily.Session(log, name, [(daily.daily_path(cfg.archive, start), None),
                                     (notes_file, f"stenographr notes · {cwd}")], start, "notes", str(cwd))
    log.info(name, f"start: {cwd}, mic {cfg.mic} channel {cfg.channel}")
    print(f"stenographr notes: listening on {cfg.mic}; Ctrl+C to stop", file=sys.stderr)

    n = 0

    def emit(segs):
        nonlocal n
        for s in segs:
            print(s["text"], flush=True)
            sess.line(s["text"])
            n += 1

    _state_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
    err = open(_state_dir() / "notes.err", "wb")
    proc = subprocess.Popen(recorder_cmd(cfg.mic, "-"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=err, start_new_session=True)
    status = daily.ok()
    rest = b""
    try:
        fd = proc.stdout.fileno()
        while not stop:
            if not select.select([fd], [], [], 0.2)[0]:
                if proc.poll() is not None:
                    status = daily.failed("recorder exited")
                    log.error(name, f"pw-record exited unexpectedly (rc {proc.returncode})")
                    break
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                status = daily.failed("recorder exited")
                log.error(name, "pw-record closed its output unexpectedly")
                break
            rest += chunk
            k = len(rest) // 8 * 8                       # whole stereo float32 frames only
            data, rest = rest[:k], rest[k:]
            emit(stream.accept(channel_of(data, cfg.channel)))
    except Exception as e:                               # noqa: BLE001
        log.error(name, f"{type(e).__name__}: {e}")
        status = daily.failed("transcription error")
    finally:
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    try:
        emit(stream.flush())                             # the sentence still in progress
    except Exception as e:                               # noqa: BLE001
        log.error(name, f"{type(e).__name__}: {e}")
        status = daily.failed("transcription error")
    sess.end(dt.datetime.now(), status)
    log.info(name, f"finish: {n} sentences, {status}")
    return 0 if status == daily.ok() else 1
