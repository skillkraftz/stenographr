"""The live screen (Textual). 80x25 cells. It only shows text and buttons; it never types into other windows.

Phases:  ready (loop only) -> [notice] -> recording -> stopping -> cleaning -> review -> (ready | exit)
A popup skips `ready` and exits after any choice; a loop goes back to `ready` (except Close).
"""
from __future__ import annotations

import asyncio
import datetime as dt
import math
import signal
import textwrap
import threading
import time

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.css.scalar import Scalar
from textual.screen import ModalScreen
from textual.widgets import Button, OptionList, RichLog, Static

from . import registry, tmuxsend
from .live import LiveSession, stop_other
from .runner import Engines, pick_device

BANNER = "Live preview · final text is cleaned up when you stop"
ALL_BUTTONS = ("start", "stop", "copy", "append", "send", "new", "close", "stopit", "cancel")


class PickSession(ModalScreen):
    """A short list of the tmux sessions that have a Claude pane."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, sessions: list[str]):
        super().__init__()
        self.sessions = sessions

    def compose(self) -> ComposeResult:
        with Vertical(id="pick"):
            yield Static("Send to which Claude?  (Esc cancels)")
            yield OptionList(*self.sessions, id="sessions")

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(self.sessions[event.option_index])

    def action_cancel(self) -> None:
        self.dismiss(None)


class LiveApp(App):
    TITLE = "stenographr live"
    CSS = """
    #banner { height: auto; background: $primary; color: $text; }
    #banner_l { width: 1fr; padding: 0 1; }
    #banner_r { width: auto; padding: 0 1; text-style: bold; }
    #status { height: auto; padding: 0 1; }
    #last { height: auto; padding: 0 1; color: $text-muted; }
    #log { height: 1fr; min-height: 3; padding: 0 1; }
    #buttons { layout: grid; grid-size: 3; padding: 0 1; }
    #buttons Button { width: 1fr; margin: 0; }
    PickSession { align: center middle; }
    #pick { width: 50; height: auto; max-height: 16; border: round $primary; background: $surface; padding: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, sessions: list[str]):
        super().__init__()
        self.sessions = sessions

    def compose(self) -> ComposeResult:
        with Vertical(id="pick"):
            yield Static("Send to which Claude?  (Esc cancels)")
            yield OptionList(*self.sessions, id="sessions")

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(self.sessions[event.option_index])

    def action_cancel(self) -> None:
        self.dismiss(None)


class LiveApp(App):
    TITLE = "stenographr live"
    CSS = """
    #banner { height: 1; background: $primary; color: $text; }
    #banner_l { width: 1fr; padding: 0 1; }
    #banner_r { width: auto; padding: 0 1; text-style: bold; }
    #status { height: 1; padding: 0 1; }
    #last { height: 1; padding: 0 1; color: $text-muted; }
    #log { height: 1fr; padding: 0 1; }
    #buttons { height: 3; padding: 0 1; }
    #buttons Button { margin: 0 1 0 0; }
    PickSession { align: center middle; }
    #pick { width: 50; height: auto; max-height: 16; border: round $primary; background: $surface; padding: 1; }
    """
    BINDINGS = [Binding("s", "stop", "Stop"), Binding("y", "yes", "Copy"), Binding("a", "append", "Claude append"), Binding("e", "send", "Claude send"),
                Binding("r", "again", "Start / New"), Binding("enter", "start", "Start", show=False),
                Binding("n", "no", "Cancel"), Binding("q", "close", "Close"), Binding("escape", "close", "Close")]

    def __init__(self, cfg, log, requested: str, popup: bool = False):
        super().__init__()
        self.cfg, self.slog, self.requested, self.popup = cfg, log, requested, popup
        self.engines = Engines(cfg, log)           # one model for the app's whole life
        self.session: LiveSession | None = None
        self.entry = None                          # registry.Entry (set by live.run)
        self.closing = False
        self.phase = "starting"        # ready | notice | recording | stopping | cleaning | review | picking | error
        self.last: tuple[str, str] | None = None   # (what happened, HH:MM) of the previous capture
        self.t_start = time.monotonic()
        self._texts = {"status": "", "last": ""}
        self.other: dict | None = None             # the instance that is recording, during the notice
        self.claude_default: str | None = None
        self.claude_panes: dict[str, str] = {}

    # ------------------------------------------------------------ layout
    def compose(self) -> ComposeResult:
        with Horizontal(id="banner"):
            yield Static(BANNER, id="banner_l")
            yield Static("", id="banner_r")                  # the project (tmux session) name, right end of the bar
        yield Static("", id="status")
        yield Static("", id="last")
        yield RichLog(id="log", wrap=True, markup=False, highlight=False, min_width=10)
        with Horizontal(id="buttons"):
            yield Button("Start (Enter or r)", id="start", variant="success")
            yield Button("Stop (s)", id="stop", variant="error")
            yield Button("Copy (y)", id="copy", variant="success")
            yield Button("Claude append (a)", id="append", variant="primary")
            yield Button("Claude send (e)", id="send", variant="warning")
            yield Button("New (r)", id="new")
            yield Button("Close (q / Esc)", id="close")
            yield Button("Stop it and record here (y)", id="stopit", variant="warning")
            yield Button("Cancel (n)", id="cancel")

    def on_mount_buttons(self) -> None:
        for b in self.query(Button):
            b.can_focus = False                        # Enter must not press a focused button (it would deliver)

    def _show(self, *ids: str) -> None:
        for i in ALL_BUTTONS:
            self.query_one(f"#{i}", Button).display = i in ids
        self._layout()

    def _layout(self) -> None:
        """Fit the buttons to the terminal: as many columns as fit (a label needs ~26 cells), one per row in a narrow
        sidebar, and one-line buttons below 40 columns. Text (banner, status, clean text) simply wraps."""
        w = max(self.size.width, 1)
        shown = [b for b in self.query(Button) if b.display]
        row = self.query_one("#buttons")
        row.styles.layout = "grid"                  # (set here: the Horizontal container's own layout wins over CSS)
        row.styles.grid_size_columns = max(1, min(len(shown) or 1, w // 26))
        row.styles.grid_gutter_vertical = 0         # (buttons have their own borders; no gutters, or rows lose a line)
        row.styles.grid_gutter_horizontal = 0
        cols = row.styles.grid_size_columns
        compact = w < 40
        nrows, h = max(1, math.ceil(len(shown) / cols)), (1 if compact else 3)
        row.styles.height = nrows * h
        row.styles.grid_rows = tuple(Scalar.parse(str(h)) for _ in range(nrows))     # explicit: auto/fr rows squeezed row 1
        for b in self.query(Button):
            b.compact = compact
            b.styles.width = "1fr"                  # (set here: the stylesheet's width/height rules don't reach these)
            b.styles.height = 1 if compact else 3
            b.styles.margin = 0
        self._fit()

    def on_resize(self, event) -> None:
        self._layout()

    def _status(self, text: str) -> None:
        self._texts["status"] = text
        self.query_one("#status", Static).update(Text(text))
        self._fit()

    def _last(self, text: str) -> None:
        self._texts["last"] = text
        self.query_one("#last", Static).update(Text(text))
        self._fit()

    def _fit(self) -> None:
        """Give wrapped one-line texts (status, last, the banner) as many rows as they need at this width."""
        w = max(self.size.width, 1)
        for sel, text, pad in (("#status", self._texts["status"], 2), ("#last", self._texts["last"], 2)):
            self.query_one(sel).styles.height = max(1, len(textwrap.wrap(text, max(w - pad, 1))) or 1)
        right = str(self.query_one("#banner_r", Static).content)
        avail = max(w - 2 - (len(right) + 2 if right else 0), 1)
        self.query_one("#banner").styles.height = max(1, len(textwrap.wrap(BANNER, avail)) or 1)

    def _label(self, bid: str, text: str) -> None:
        self.query_one(f"#{bid}", Button).label = text

    def _project(self, name: str = "") -> None:
        """Right end of the blue bar: the Claude target's session when known, else this instance's own tmux session."""
        own = self.entry.data["where"] if self.entry else ""
        self.query_one("#banner_r", Static).update(Text(name or (own if own not in ("terminal", "popup") else "")))
        self._fit()

    def _post(self, fn, *args) -> None:
        try:
            self.call_from_thread(fn, *args)
        except Exception:                              # noqa: BLE001 - the app is already gone
            pass

    def _set_recording(self, on: bool) -> None:
        if self.entry:
            self.entry.set_recording(on)

    # ------------------------------------------------------------ start
    def on_mount(self) -> None:
        self.on_mount_buttons()
        self._project()
        self._show()
        self.set_interval(1.0, self._tick)
        try:                                           # `live --toggle`, or another instance, sends SIGUSR1 = stop
            asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, self.action_stop)
        except (RuntimeError, NotImplementedError, ValueError):
            pass
        threading.Thread(target=self._preload, daemon=True).start()
        if self.popup:
            self._begin()
        else:
            self._to_ready()

    def _preload(self) -> None:
        """Load the model in the background, once, for the app's lifetime (a capture that starts before it is
        loaded keeps all its audio: the recorder runs first and is queued)."""
        try:
            self.engines.get(pick_device(self.cfg, self.slog, "live", self.requested), "live")
        except Exception as e:                         # noqa: BLE001 - a capture will fall back or report it
            self.slog.error("live", f"preloading the model failed: {type(e).__name__}: {e}")

    def _tick(self) -> None:
        if self.phase == "recording":
            s = int(time.monotonic() - self.t_start)
            self._status(f"● Recording {s // 60:02d}:{s % 60:02d} · stop: s, the button, or Ctrl+`")

    # ------------------------------------------------------------ ready (loop)
    def _to_ready(self, message: str = "Ready") -> None:
        self.phase = "ready"
        self._status(message)
        self._last(f"Last: {self.last[0]} · {self.last[1]}" if self.last else "")
        self.query_one("#log", RichLog).clear()
        self._label("close", "Close (q)")
        self._show("start", "close")

    # ------------------------------------------------------------ start a capture (one recording at a time)
    def _begin(self) -> None:
        other = registry.recording_elsewhere()
        if other:
            self.phase = "notice"
            self.other = other
            self._status(f"Recording in {other['where']}. Stop it and record here?")
            self._show("stopit", "cancel")
            return
        self._start_capture()

    def _stop_it(self) -> None:
        self._status("Stopping the other recording…")
        self._show()
        other = self.other

        def work():
            ok = stop_other(other)
            self._post(self._after_stop_other, ok)

        threading.Thread(target=work, daemon=True).start()

    def _after_stop_other(self, ok: bool) -> None:
        if ok:
            self._start_capture()
        elif self.popup:
            self.phase = "error"
            self._status("The other recording did not stop.")
            self._label("close", "Close (q)")
            self._show("close")
        else:
            self._to_ready("The other recording did not stop.")

    def _start_capture(self) -> None:
        self.session = LiveSession(self.cfg, self.slog, self.requested, self.engines)
        err = self.session.preflight()
        if err:
            if self.popup:
                self.phase = "error"
                self._status(f"Cannot record: {err}")
                self._label("close", "Close (q)")
                self._show("close")
            else:
                self.session = None
                self._to_ready(f"Cannot record: {err}")
            return
        self.phase = "recording"
        self.t_start = time.monotonic()
        self._set_recording(True)
        self.query_one("#log", RichLog).clear()
        self._last("")
        self._show("stop")
        self._tick()
        self.session.on_phrase = lambda t: self._post(self._add_phrase, t)
        self.session.record_thread = threading.Thread(target=self._record_main, args=(self.session,), daemon=True)
        self.session.record_thread.start()

    def _add_phrase(self, text: str) -> None:
        self.query_one("#log", RichLog).write(text)

    # ------------------------------------------------------------ record -> clean -> review
    def _record_main(self, session: LiveSession) -> None:
        session.record()
        self._set_recording(False)                     # the microphone is free: another instance may record now
        self._post(self._recorded, session)

    def _recorded(self, session: LiveSession) -> None:
        if session is not self.session:
            return
        if session.result is None:
            self.phase = "error"
            self._status("Recording failed, see steno.log")
            self._label("close", "Close (q)")
            self._show("close")
            return
        self.phase = "cleaning"
        self._show()
        self._status("Cleaning up…")
        session.clean_thread = threading.Thread(target=self._clean_main, args=(session,), daemon=True)
        session.clean_thread.start()

    def _clean_main(self, session: LiveSession) -> None:
        try:
            session.clean()
        except Exception:                              # noqa: BLE001 - logged; the live text is used instead
            pass
        self._post(self._review, session)

    def _review(self, session: LiveSession) -> None:
        if session is not self.session:
            return
        text = session.text()
        log = self.query_one("#log", RichLog)
        log.clear()
        self._label("close", "Close (q / Esc)")
        again = () if self.popup else ("new",)
        if not text:
            self.phase = "review"
            self._status("No speech heard.")
            self._show(*again, "close")
            return
        log.write(text)
        self._status("Clean-up failed: this is the live text (see steno.log)" if session.clean_failed
                     else "Clean text:")
        self.claude_default, self.claude_panes = tmuxsend.choose_target()
        for bid in ("append", "send"):
            self.query_one(f"#{bid}", Button).disabled = not self.claude_panes      # no claude pane: both disabled
        self._project(self.claude_default or "")
        self.phase = "review"
        self._show("copy", "append", "send", *again, "close")

    # ------------------------------------------------------------ actions (keys and buttons)
    def action_stop(self) -> None:
        if self.phase == "recording":
            self.phase = "stopping"
            self._status("Stopping…")
            self.session.request_stop()

    def action_yes(self) -> None:                      # y: Copy at the button step, "Stop it" in the notice
        if self.phase == "notice":
            self._stop_it()
        elif self.phase == "review" and self.session and self.session.text():
            self._choose("copy")

    def action_no(self) -> None:                       # n: Cancel in the notice
        if self.phase == "notice":
            self._cancel_notice()

    def action_start(self) -> None:                    # Enter: Start, on the ready screen only (never at the button step)
        if self.phase == "ready":
            self._begin()

    def action_again(self) -> None:                    # r: Start on ready, New at the button step
        if self.phase == "ready":
            self._begin()
        elif self.phase == "review" and not self.popup:
            self._choose("new")

    def action_close(self) -> None:                    # q / Esc
        if self.phase == "notice":
            self._cancel_notice()
        elif self.phase == "review":
            self._choose("close")
        elif self.phase in ("ready", "error"):
            self.exit()

    def action_append(self) -> None:                   # a: type the text + a space into Claude's input (no Enter)
        self._claude("append")

    def action_send(self) -> None:                     # e: type the text, then press Enter (the only Enter there is)
        self._claude("send")

    def _claude(self, choice: str) -> None:
        if self.phase != "review" or not self.claude_panes or not self.session or not self.session.text():
            return
        if self.claude_default:
            self._choose(choice, self.claude_default)
            return
        self.phase = "picking"

        def picked(session: str | None) -> None:
            self.phase = "review"
            if session:
                self._choose(choice, session)

        self.push_screen(PickSession(sorted(self.claude_panes)), picked)

    def _cancel_notice(self) -> None:
        self.other = None
        if self.popup:
            self.exit()
        else:
            self._to_ready()

    def _choose(self, choice: str, claude_session: str | None = None) -> None:
        session = self.session
        status = session.deliver(choice, claude_session)
        if status.startswith("FAILED"):                # keep the text on screen so it can be copied by hand
            self.phase = "error"
            self._status(status)
            self._label("close", "Close (q)")
            self._show("close")
            return
        word = {"copy": "copied", "new": "new take", "close": "closed",
                "append": f"appended to claude {claude_session}", "send": f"sent to claude {claude_session}"}[choice]
        self.last = (word, dt.datetime.now().strftime("%H:%M"))
        self.session = None
        if self.popup or choice == "close":
            self.exit()
        else:
            self._to_ready()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id
        if bid == "start":
            self.action_again()
        elif bid == "stop":
            self.action_stop()
        elif bid == "copy":
            self.action_yes()
        elif bid == "append":
            self.action_append()
        elif bid == "send":
            self.action_send()
        elif bid == "new":
            self.action_again()
        elif bid == "close":
            self.action_close()
        elif bid == "stopit":
            self._stop_it()
        elif bid == "cancel":
            self._cancel_notice()
