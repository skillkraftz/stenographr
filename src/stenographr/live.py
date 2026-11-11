"""`stenographr live`: the live session core (no UI here; live_ui.py is the Textual screen).

Two kinds of instance (see SPEC.md):
  popup  opened by Ctrl+` (`live --toggle`) in a kitty window: records at once, one capture, then the window closes.
  loop   `stenographr live` in a terminal or tmux pane: a ready screen, any number of captures; the model is loaded
         once for the app's lifetime.

One capture = a LiveSession: record (live phrases shown and appended to the daily file as they come) -> stop ->
clean pass (the session's whole audio in one go, whole sentences) -> the user's choice -> clean block + end line in
the daily file. It never types into other windows. Only one instance records at a time (registry.py).

Daily block:
  start: ... · live · unknown · audio/<...>-live.opus
  [HH:MM:SS] <live phrase>        (as they come, so a crash keeps everything said)
  clean:
  [HH:MM:SS] <clean sentence or paragraph>
  end: ... · 1m30s · ok · copied   (copied | appended to claude <session> | sent to claude <session> | new take | closed)
"""
from __future__ import annotations

import datetime as dt
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

from . import daily, registry, tmuxsend
from .dictate import LiveResult, _copy, _fail_block, _live
from .log import Log
from .record import SR, mic_exists
from .runner import Engines, transcribe_audio

NAME = "live"
WORDS = {"copy": "copied", "new": "new take", "close": "closed"}       # append/send: "appended to / sent to claude <session>"


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


# ---------------------------------------------------------------- Ctrl+`

def toggle(cfg, log: Log, config_arg: str | None = None) -> int:
    """Ctrl+`. Only popups matter here; pane/terminal instances are never touched.
      a popup is recording -> stop it;  a popup exists otherwise (notice, cleaning, buttons) -> nothing;
      no popup (and none being launched) -> open a kitty window with one."""
    popups = [i for i in registry.instances() if i["kind"] == "popup"]
    if popups:
        if popups[0]["recording"]:
            os.kill(popups[0]["pid"], signal.SIGUSR1)
            log.info(NAME, f"stop requested (popup pid {popups[0]['pid']})")
        return 0
    if registry.launching_recently():
        return 0                                   # a popup is on its way up: never open a second one
    kitty = shutil.which("kitty")
    if not kitty:
        log.error(NAME, "kitty not found: cannot open the live window")
        return 1
    registry.mark_launching()
    cmd = [kitty, "--title", "stenographr live", "--class", "stenographr-live",
           "-o", "initial_window_width=80c", "-o", "initial_window_height=25c", "-o", "remember_window_size=no",
           sys.executable, "-m", "stenographr.cli"] + (["--config", config_arg] if config_arg else []) + ["live", "--popup"]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    log.info(NAME, "opened the live popup")
    return 0


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


# ---------------------------------------------------------------- one capture

class LiveSession:
    def __init__(self, cfg, log: Log, requested: str, engines: Engines | None = None):
        self.cfg, self.log, self.requested = cfg, log, requested
        self.engines = engines                     # shared for the app's lifetime (None: one per capture)
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

    # -- record (blocking; runs in a thread)
    def record(self) -> LiveResult | None:
        start = dt.datetime.now()
        try:
            self.result = _live(self.cfg, self.log, self.requested, NAME, "live", "unknown",
                                [(daily.daily_path(self.cfg.archive, start), None)], self._phrase,
                                stop_event=self.stop_event, signals=False, finish=False, keep_pcm=True,
                                engines=self.engines)
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
        """choice: copy | append | send | new | close. Writes the end line and returns it ('ok · copied',
        'ok · appended to claude alpha', 'ok · sent to claude alpha', 'ok · new take', 'ok · closed', 'FAILED: ...').
        Copy and append add one trailing space (so the next take, or typing, starts clean); send presses Enter."""
        r = self.result
        base = r.status if r else daily.failed("recording failed")
        text = self.text()
        how, problem = WORDS.get(choice, "closed"), None
        if choice == "copy" and text:
            try:
                _copy(text + " ")
            except Exception as e:                 # noqa: BLE001
                self.log.error(NAME, f"clipboard (wl-copy) failed: {type(e).__name__}: {e}")
                problem = "clipboard failed"
        elif choice in ("append", "send") and text:
            try:
                tmuxsend.send(tmuxsend.claude_panes()[claude_session], text, enter=(choice == "send"))
                how = f"{'sent' if choice == 'send' else 'appended'} to claude {claude_session}"
            except Exception as e:                 # noqa: BLE001
                self.log.error(NAME, f"{choice} to claude {claude_session} failed: {type(e).__name__}: {e}")
                problem = f"{choice} to claude failed"
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

def run(cfg, log: Log, requested: str, popup: bool = False, headless: bool = False) -> int:
    from .live_ui import LiveApp                   # Textual is only needed here

    app = LiveApp(cfg, log, requested, popup=popup)
    app.entry = registry.Entry("popup" if popup else "loop", detect_where(popup))

    def closing(*_):                               # window closed (SIGHUP) or killed (SIGTERM): finish up below
        app.closing = True
        if app.session:
            app.session.request_stop()
        try:
            app.exit()
        except Exception:                          # noqa: BLE001
            pass

    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, closing)
    try:
        app.run(headless=headless)
    finally:
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):    # a second hang-up must not cut the wrap-up short
            signal.signal(sig, signal.SIG_IGN)
        try:
            if app.session:
                app.session.finalize_on_exit()
        finally:
            app.entry.remove()
    return 0
