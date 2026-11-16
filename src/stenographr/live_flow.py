"""The live flow: what happens when, as transitions of `LiveState` (live_state.py). No Textual here.

The screen (live_ui.py) is the `view`: it only draws what the flow tells it and calls the flow's `on_*` methods for
user actions. The flow starts the capture, follows it through record -> clean -> review and delivers the choice.
Threads (preload, record, clean, stop-other) report back through `view.post`, which runs on the screen's loop.

View interface: status(text), last(text), buttons(*ids), clear_log(), write_log(text), render_live(lines, partial),
set_project(name), set_claude_enabled(bool), pick_session(names, callback), exit(), post(fn, *args).
"""
from __future__ import annotations

import datetime as dt
import threading
import time

from . import registry, tmuxsend
from .live import LiveSession, stop_other
from .live_state import LiveState, Phase as P
from .runner import Engines


class LiveFlow:
    def __init__(self, cfg, log, requested: str, popup: bool, view):
        self.cfg, self.slog, self.requested, self.popup, self.view = cfg, log, requested, popup, view
        self.engines = Engines(cfg, log)           # one model for the app's whole life
        self.state = LiveState(log)
        self.session: LiveSession | None = None
        self.entry = None                          # registry.Entry (set by live.run)
        self.last: tuple[str, str] | None = None   # (what happened, HH:MM) of the previous capture
        self.t_start = time.monotonic()
        self.other: dict | None = None             # the instance that is recording, during the notice
        self.claude_default: str | None = None
        self.claude_pane: str | None = None
        self.claude_panes: dict[str, str] = {}

    @property
    def phase(self) -> P:
        return self.state.phase

    # ------------------------------------------------------------ start
    def start(self) -> None:
        threading.Thread(target=self._preload, daemon=True).start()
        if self.popup:
            self._begin()
        else:
            self._to_ready()

    def _preload(self) -> None:
        """Load the model in the background, once, for the app's lifetime (a capture that starts before it is
        loaded keeps all its audio: the recorder runs first and is queued)."""
        try:
            self.engines.get_stream("live")            # the preview model first: a capture needs it at once
        except Exception as e:                         # noqa: BLE001 - a capture falls back to the per-phrase decode
            self.slog.error("live", f"preloading the streaming model failed: {type(e).__name__}: {e}")
        try:
            self.engines.get(self.engines.decide(self.requested, "live"), "live")     # the clean pass at stop
        except Exception as e:                         # noqa: BLE001 - a capture will fall back or report it
            self.slog.error("live", f"preloading the model failed: {type(e).__name__}: {e}")

    def set_recording(self, on: bool) -> None:
        if self.entry:
            self.entry.set_recording(on)

    def tick(self) -> None:
        if self.state.is_in(P.RECORDING):
            s = int(time.monotonic() - self.t_start)
            self.view.status(f"● Recording {s // 60:02d}:{s % 60:02d} · stop: s, the button, or Ctrl+`")

    def _error(self, text: str) -> None:
        self.state.go(P.ERROR)
        self.view.status(text)
        self.view.buttons("close")

    # ------------------------------------------------------------ ready (loop)
    def _to_ready(self, message: str = "Ready") -> None:
        self.state.go(P.READY)
        self.view.status(message)
        self.view.last(f"Last: {self.last[0]} · {self.last[1]}" if self.last else "")
        self.view.clear_log()
        self.view.buttons("start", "close")

    # ------------------------------------------------------------ start a capture (one recording at a time)
    def _begin(self) -> None:
        other = registry.recording_elsewhere()
        if other:
            self.state.go(P.NOTICE)
            self.other = other
            self.view.status(f"Recording in {other['where']}. Stop it and record here?")
            self.view.buttons("stopit", "cancel")
            return
        self._start_capture()

    def _stop_it(self) -> None:
        self.view.status("Stopping the other recording…")
        self.view.buttons()
        other = self.other

        def work():
            ok = stop_other(other)
            self.view.post(self._after_stop_other, ok)

        threading.Thread(target=work, daemon=True).start()

    def _after_stop_other(self, ok: bool) -> None:
        if ok:
            self._start_capture()
        elif self.popup:
            self._error("The other recording did not stop.")
        else:
            self._to_ready("The other recording did not stop.")

    def _start_capture(self) -> None:
        self.session = LiveSession(self.cfg, self.slog, self.requested, self.engines)
        err = self.session.preflight()
        if err:
            if self.popup:
                self._error(f"Cannot record: {err}")
            else:
                self.session = None
                self._to_ready(f"Cannot record: {err}")
            return
        self.state.go(P.RECORDING)
        self.t_start = time.monotonic()
        self.set_recording(True)
        self.state.reset_text()
        self.view.clear_log()
        self.view.last("")
        self.view.buttons("stop")
        self.tick()
        self.session.on_phrase = lambda t: self.view.post(self.add_phrase, t)
        self.session.on_partial = lambda t: self.view.post(self.set_partial, t)
        self.session.record_thread = threading.Thread(target=self._record_main, args=(self.session,), daemon=True)
        self.session.record_thread.start()

    def add_phrase(self, text: str) -> None:
        self.state.add_phrase(text)
        self.view.render_live(self.state.lines, self.state.partial)

    def set_partial(self, text: str) -> None:
        if self.state.set_partial(text):
            self.view.render_live(self.state.lines, self.state.partial)

    # ------------------------------------------------------------ record -> clean -> review
    def _record_main(self, session: LiveSession) -> None:
        session.record()
        self.set_recording(False)                      # the microphone is free: another instance may record now
        self.view.post(self._recorded, session)

    def _recorded(self, session: LiveSession) -> None:
        if session is not self.session:
            return
        if session.result is None:
            self._error("Recording failed, see steno.log")
            return
        self.state.go(P.CLEANING)
        self.view.buttons()
        self.view.status("Cleaning up…")
        session.clean_thread = threading.Thread(target=self._clean_main, args=(session,), daemon=True)
        session.clean_thread.start()

    def _clean_main(self, session: LiveSession) -> None:
        try:
            session.clean()
        except Exception:                              # noqa: BLE001 - logged; the live text is used instead
            pass
        self.view.post(self._review, session)

    def _review(self, session: LiveSession) -> None:
        if session is not self.session:
            return
        text = session.text()
        self.view.clear_log()
        again = () if self.popup else ("new",)
        if not text:
            self.state.go(P.REVIEW)
            self.view.status("No speech heard.")
            self.view.buttons(*again, "close")
            return
        self.view.write_log(text)
        self.claude_default, self.claude_pane, self.claude_panes, notice = tmuxsend.choose_target()
        self.view.status(("Clean-up failed: this is the live text (see steno.log)" if session.clean_failed
                          else "Clean text:") + (f" ({notice})" if notice else ""))
        self.view.set_claude_enabled(bool(self.claude_pane or self.claude_panes))      # no target: both disabled
        self.view.set_project(self.claude_default or "")
        self.state.go(P.REVIEW)
        self.view.buttons("copy", "append", "send", *again, "close")

    # ------------------------------------------------------------ user actions (keys and buttons)
    def on_stop(self) -> None:
        if self.state.is_in(P.RECORDING):
            self.state.go(P.STOPPING)
            self.view.status("Stopping…")
            self.session.request_stop()

    def on_yes(self) -> None:                          # y: Copy at the button step, "Stop it" in the notice
        if self.state.is_in(P.NOTICE):
            self._stop_it()
        elif self.state.is_in(P.REVIEW) and self.session and self.session.text():
            self._choose("copy")

    def on_no(self) -> None:                           # n: Cancel in the notice
        if self.state.is_in(P.NOTICE):
            self._cancel_notice()

    def on_start(self) -> None:                        # Enter: Start, on the ready screen only (never at the button step)
        if self.state.is_in(P.READY):
            self._begin()

    def on_again(self) -> None:                        # r: Start on ready, New at the button step
        if self.state.is_in(P.READY):
            self._begin()
        elif self.state.is_in(P.REVIEW) and not self.popup:
            self._choose("new")

    def on_close(self) -> None:                        # q / Esc
        if self.state.is_in(P.NOTICE):
            self._cancel_notice()
        elif self.state.is_in(P.REVIEW):
            self._choose("close")
        elif self.state.is_in(P.READY, P.ERROR):
            self.view.exit()

    def on_stop_it(self) -> None:
        self._stop_it()

    def on_cancel(self) -> None:
        self._cancel_notice()

    def on_claude(self, choice: str) -> None:          # append: text + a space, no Enter; send: text, then Enter (the only Enter there is)
        if not self.state.is_in(P.REVIEW) or not (self.claude_pane or self.claude_panes) or not self.session or not self.session.text():
            return
        if self.claude_default:
            self._choose(choice, self.claude_default, self.claude_pane)
            return
        self.state.go(P.PICKING)

        def picked(name: str | None) -> None:
            self.state.go(P.REVIEW)
            if name:
                self._choose(choice, name)

        self.view.pick_session(sorted(self.claude_panes), picked)

    def _cancel_notice(self) -> None:
        self.other = None
        if self.popup:
            self.view.exit()
        else:
            self._to_ready()

    def _choose(self, choice: str, claude_session: str | None = None, pane: str | None = None) -> None:
        status = self.session.deliver(choice, claude_session, pane)
        if status.startswith("FAILED"):                # keep the text on screen so it can be copied by hand
            self._error(status)
            return
        word = {"copy": "copied", "new": "new take", "close": "closed",
                "append": f"appended to claude {claude_session}", "send": f"sent to claude {claude_session}"}[choice]
        self.last = (word, dt.datetime.now().strftime("%H:%M"))
        self.session = None
        if self.popup or choice == "close":
            self.view.exit()
        else:
            self._to_ready()
