"""`stenographr live`: the live session core (no UI here; live_ui.py is the Textual screen).

Flow: record (live phrases shown and appended to the daily file as they come) -> stop -> clean pass (the session's
whole audio in one go, whole sentences) -> the user picks Copy / Send to Claude / Don't copy -> clean block + end
line in the daily file. It never types into other windows.

Daily block:
  start: ... · live · unknown · audio/<...>-live.opus
  [HH:MM:SS] <live phrase>        (as they come, so a crash keeps everything said)
  clean:
  [HH:MM:SS] <clean sentence or paragraph>
  end: ... · 1m30s · ok · copied
"""
from __future__ import annotations

import datetime as dt
import os
import shutil
import signal
import subprocess
import sys
import threading
import traceback
from pathlib import Path

from . import daily, tmuxsend
from .dictate import LiveResult, _copy, _fail_block, _live, _state_dir
from .log import Log
from .record import SR, mic_exists
from .runner import transcribe_audio

NAME = "live"


# ---------------------------------------------------------------- the running-session marker

def _pidfile() -> Path:
    return _state_dir() / "live.pid"


def find_running() -> int | None:
    """The pid of a running `stenographr live` (checked against /proc, so a stale file or reused pid doesn't count)."""
    try:
        pid = int(_pidfile().read_text().split()[0])
        args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (OSError, ValueError, IndexError):
        return None
    ours = any(b"stenographr" in a for a in args) and b"live" in args and b"--toggle" not in args
    return pid if ours and state != "Z" else None


def toggle(cfg, log: Log, config_arg: str | None = None) -> int:
    """Ctrl+`: a live session is running -> tell it to stop (SIGUSR1); otherwise open a kitty window with one."""
    pid = find_running()
    if pid:
        os.kill(pid, signal.SIGUSR1)
        log.info(NAME, f"stop requested (pid {pid})")
        return 0
    kitty = shutil.which("kitty")
    if not kitty:
        log.error(NAME, "kitty not found: cannot open the live window")
        return 1
    cmd = [kitty, "--title", "stenographr live", "--class", "stenographr-live",
           "-o", "initial_window_width=80c", "-o", "initial_window_height=25c", "-o", "remember_window_size=no",
           sys.executable, "-m", "stenographr.cli"] + (["--config", config_arg] if config_arg else []) + ["live"]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    log.info(NAME, "opened the live window")
    return 0


# ---------------------------------------------------------------- the session

class LiveSession:
    def __init__(self, cfg, log: Log, requested: str):
        self.cfg, self.log, self.requested = cfg, log, requested
        self.stop_event = threading.Event()
        self.on_phrase = None                      # callback(text), called from the recording thread
        self.result: LiveResult | None = None
        self.clean_text = ""
        self.clean_failed = False
        self.cleaned = False
        self.done = False
        self.record_thread: threading.Thread | None = None
        self.clean_thread: threading.Thread | None = None

    # -- start
    def preflight(self) -> str | None:
        """An error message if recording can't start (the daily file gets a FAILED block), else None."""
        if mic_exists(self.cfg.mic):
            return None
        self.log.error(NAME, f"mic {self.cfg.mic} not found: nothing recorded")
        now = dt.datetime.now()
        _fail_block(self.cfg, self.log, NAME, "live", "unknown", now, f"mic {self.cfg.mic} not found")
        self.done = True
        return f"mic {self.cfg.mic} not found"

    def mark_running(self) -> None:
        _state_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
        _pidfile().write_text(f"{os.getpid()}\n")

    def unmark_running(self) -> None:
        try:
            if _pidfile().read_text().split()[0] == str(os.getpid()):
                _pidfile().unlink()
        except (OSError, IndexError):
            pass

    # -- record (blocking; runs in a thread)
    def record(self) -> LiveResult | None:
        start = dt.datetime.now()
        try:
            self.result = _live(self.cfg, self.log, self.requested, NAME, "live", "unknown",
                                [(daily.daily_path(self.cfg.archive, start), None)], self._phrase,
                                stop_event=self.stop_event, signals=False, finish=False, keep_pcm=True)
        except Exception as e:                     # noqa: BLE001
            self.log.error(NAME, f"recording failed: {type(e).__name__}: {e}")
            _fail_block(self.cfg, self.log, NAME, "live", "unknown", start, "recording failed")
            self.done = True
        return self.result

    def _phrase(self, text: str) -> None:
        if self.on_phrase:
            self.on_phrase(text)

    def request_stop(self) -> None:
        self.stop_event.set()

    # -- clean pass
    def clean(self) -> str:
        """Re-transcribe the whole session in one pass and write the `clean:` block. Returns the clean text."""
        r = self.result
        self.cleaned = True
        if r is None or not r.texts or r.pcm is None or len(r.pcm) < 0.3 * SR:
            return ""
        try:
            segs, _ = transcribe_audio(self.cfg, self.log, r.engines, NAME, r.pcm, self.requested,
                                       method="transcribe_long")
        except Exception as e:                     # noqa: BLE001
            self.clean_failed = True
            tb = traceback.extract_tb(e.__traceback__)[-1]
            self.log.error(NAME, f"clean pass failed: {type(e).__name__}: {e} (at {Path(tb.filename).name}:{tb.lineno})")
            raise
        lines = [(r.t0 + dt.timedelta(seconds=s["start"]), s["text"].strip()) for s in segs if s["text"].strip()]
        if not lines:                              # the pass found nothing: keep what was said live
            self.log.warn(NAME, "clean pass returned no text: using the live phrases")
            lines = [(r.t0, " ".join(r.texts))]
        r.sess.marker("clean:")
        for when, text in lines:
            r.sess.line(text, when)
        self.clean_text = " ".join(t for _, t in lines)
        return self.clean_text

    def text(self) -> str:
        """What gets delivered: the clean text (or the live phrases if the clean pass failed)."""
        if self.clean_text:
            return self.clean_text
        return " ".join(self.result.texts) if self.result else ""

    # -- the user's choice
    def deliver(self, choice: str, claude_session: str | None = None) -> str:
        """choice: copy | claude | none. Writes the end line and returns it ('ok · copied', 'FAILED: ...', ...)."""
        r = self.result
        base = r.status if r else daily.failed("recording failed")
        text = self.text()
        how, problem = "not copied", None
        if choice == "copy" and text:
            try:
                _copy(text)
                how = "copied"
            except Exception as e:                 # noqa: BLE001
                self.log.error(NAME, f"clipboard (wl-copy) failed: {type(e).__name__}: {e}")
                problem = "clipboard failed"
        elif choice == "claude" and text:
            try:
                pane = tmuxsend.claude_panes()[claude_session]
                tmuxsend.send(pane, text)
                how = f"sent to claude {claude_session}"
            except Exception as e:                 # noqa: BLE001
                self.log.error(NAME, f"send to claude {claude_session} failed: {type(e).__name__}: {e}")
                problem = "send to claude failed"
        if not text:
            status = base
        elif problem:
            status = daily.failed(problem)
        elif base.startswith("FAILED"):
            status = base
        else:
            status = f"{base} · {how}"
            if self.clean_failed:
                status += " (live text: clean pass failed, see steno.log)"
        self._end(status)
        return status

    def _end(self, status: str) -> None:
        if self.done:
            return
        self.done = True
        if self.result and self.result.sess:
            self.result.sess.end(dt.datetime.now(), status)
        self.log.info(NAME, f"finish: {len(self.result.texts) if self.result else 0} phrases, {status}")

    # -- the window went away (X button, SIGHUP/SIGTERM) or the UI crashed: stop, clean if possible, no delivery
    def finalize_on_exit(self) -> None:
        if self.done:
            return
        self.stop_event.set()
        if self.record_thread and self.record_thread.is_alive():
            self.record_thread.join(timeout=30)
        if self.clean_thread and self.clean_thread.is_alive():
            self.clean_thread.join(timeout=120)
        if self.result is None:
            return
        if not self.cleaned:
            try:
                self.clean()
            except Exception:                      # noqa: BLE001 - logged in clean()
                pass
        if self.clean_failed:
            self._end(daily.failed("clean pass failed"))
        else:
            self._end(f"{self.result.status} · not copied (window closed)"
                      if self.result.texts else self.result.status)


# ---------------------------------------------------------------- the entry point

def run(cfg, log: Log, requested: str, headless: bool = False) -> int:
    from .live_ui import LiveApp                   # Textual is only needed here

    running = find_running()
    if running:
        print(f"stenographr: a live session is already running (pid {running})", file=sys.stderr)
        return 1
    session = LiveSession(cfg, log, requested)
    app = LiveApp(session)

    def closing(*_):                               # window closed (SIGHUP) or killed (SIGTERM): finish up below
        session.request_stop()
        try:
            app.exit()
        except Exception:                          # noqa: BLE001
            pass

    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, closing)
    session.mark_running()
    try:
        app.run(headless=headless)
    finally:
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):    # a second hang-up must not cut the wrap-up short
            signal.signal(sig, signal.SIG_IGN)
        try:
            session.finalize_on_exit()
        finally:
            session.unmark_running()
    return 0
