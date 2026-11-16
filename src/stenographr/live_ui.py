"""The live screen (Textual). about 80x25 cells, any size works. It only draws what the flow (live_flow.py) tells it
and passes keys and buttons on as user actions; the phases and their transitions are in live_state.py.
It never types, except the Append and Send buttons.
"""
from __future__ import annotations

import asyncio
import signal
import textwrap

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, OptionList, RichLog, Static

from .live_flow import LiveFlow

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
    #banner { height: 1; background: $primary; color: $text; }
    #banner_l { width: 1fr; padding: 0 1; }
    #banner_r { width: auto; padding: 0 1; text-style: bold; }
    #status { height: 1; padding: 0 1; }
    #last { height: 1; padding: 0 1; color: $text-muted; }
    #log { height: 1fr; padding: 0 1; }
    #buttons { layout: grid; grid-size: 5; grid-rows: 1; height: auto; padding: 0 1; }
    #buttons Button { width: 1fr; height: 1; min-width: 0; margin: 0; border: none; }
    #buttons.-mid { grid-size: 3; }
    #buttons.-narrow { grid-size: 2; }
    PickSession { align: center middle; }
    #pick { width: 50; height: auto; max-height: 16; border: round $primary; background: $surface; padding: 1; }
    """
    BINDINGS = [Binding("s", "stop", "Stop"), Binding("y", "yes", "Copy"), Binding("a", "append", "Claude append"), Binding("e", "send", "Claude send"),
                Binding("r", "again", "Start / New"), Binding("enter", "start", "Start", show=False),
                Binding("n", "no", "Cancel"), Binding("q", "close", "Close"), Binding("escape", "close", "Close")]


    def __init__(self, cfg, log, requested: str, popup: bool = False):
        super().__init__()
        self.popup, self.closing = popup, False
        self._texts = {"status": "", "last": ""}
        self.flow = LiveFlow(cfg, log, requested, popup, self)      # the state and what happens when; this class draws it

    # what tests and live.run() reach for: the flow's state
    phase = property(lambda self: self.flow.phase)
    session = property(lambda self: self.flow.session)
    engines = property(lambda self: self.flow.engines)
    _lines = property(lambda self: self.flow.state.lines)
    _partial_text = property(lambda self: self.flow.state.partial)

    @property
    def entry(self):
        return self.flow.entry

    @entry.setter
    def entry(self, value) -> None:
        self.flow.entry = value

    def _add_phrase(self, text: str) -> None:
        self.flow.add_phrase(text)

    def _set_partial(self, text: str) -> None:
        self.flow.set_partial(text)

    # ------------------------------------------------------------ layout
    def compose(self) -> ComposeResult:
        with Horizontal(id="banner"):
            yield Static(BANNER, id="banner_l")
            yield Static("", id="banner_r")                  # the project (tmux session) name, right end of the bar
        yield Static("", id="status")
        yield Static("", id="last")
        yield RichLog(id="log", wrap=True, markup=False, highlight=False, min_width=10)
        with Horizontal(id="buttons"):
            yield Button("Start r", id="start", variant="success")
            yield Button("Stop s", id="stop", variant="error")
            yield Button("Copy y", id="copy", variant="success")
            yield Button("Append a", id="append", variant="primary")
            yield Button("Send e", id="send", variant="warning")
            yield Button("New r", id="new")
            yield Button("Close q", id="close")
            yield Button("Stop it y", id="stopit", variant="warning")
            yield Button("Cancel n", id="cancel")

    def on_mount_buttons(self) -> None:
        for b in self.query(Button):
            b.can_focus = False                        # Enter must not press a focused button (it would deliver)

    def buttons(self, *ids: str) -> None:
        for i in ALL_BUTTONS:
            self.query_one(f"#{i}", Button).display = i in ids
        self._layout()

    def _layout(self) -> None:
        """The button grid is CSS (one row per 5/3/2 buttons, 1 row tall each); the only code is the width class."""
        w = self.size.width
        row = self.query_one("#buttons")
        row.set_class(0 < w < 36, "-narrow")
        row.set_class(36 <= w < 60, "-mid")
        for b in self.query(Button):
            b.compact = True
        self._fit()

    def on_resize(self, event) -> None:
        self._layout()

    def status(self, text: str) -> None:
        self._texts["status"] = text
        self.query_one("#status", Static).update(Text(text))
        self._fit()

    def last(self, text: str) -> None:
        self._texts["last"] = text
        self.query_one("#last", Static).update(Text(text))
        self.query_one("#last").display = bool(text)      # no empty row when there is nothing to say
        self._fit()

    def _fit(self) -> None:
        """Give wrapped one-line texts (status, last, the banner) as many rows as they need at this width."""
        w = max(self.size.width, 1)
        for sel, text, pad in (("#status", self._texts["status"], 2), ("#last", self._texts["last"], 2)):
            self.query_one(sel).styles.height = max(1, len(textwrap.wrap(text, max(w - pad, 1))) or 1)
        right = str(self.query_one("#banner_r", Static).content)
        avail = max(w - 2 - (len(right) + 2 if right else 0), 1)
        self.query_one("#banner").styles.height = max(1, len(textwrap.wrap(BANNER, avail)) or 1)

    def set_project(self, name: str = "") -> None:
        """Right end of the blue bar: the Claude target's session when known, else this instance's own tmux session."""
        own = self.flow.entry.data["where"] if self.flow.entry else ""
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

    def post(self, fn, *args) -> None:                 # from a thread, onto the screen's loop
        try:
            self.call_from_thread(fn, *args)
        except Exception:                              # noqa: BLE001 - the app is already gone
            pass

    def render_live(self, lines: list[str], partial: str) -> None:
        """The finished lines plus the line in progress (RichLog only appends, so it is redrawn)."""
        log = self.query_one("#log", RichLog)
        log.clear()
        for t in lines:
            log.write(t)
        if partial:
            log.write(partial)

    def clear_log(self) -> None:
        self.query_one("#log", RichLog).clear()

    def write_log(self, text: str) -> None:
        self.query_one("#log", RichLog).write(text)

    def set_claude_enabled(self, on: bool) -> None:
        for bid in ("append", "send"):
            self.query_one(f"#{bid}", Button).disabled = not on

    def pick_session(self, names: list[str], callback) -> None:
        self.push_screen(PickSession(names), callback)

    # ------------------------------------------------------------ start
    def on_mount(self) -> None:
        self.on_mount_buttons()
        self.set_project()
        self.buttons()
        self.set_interval(1.0, self.flow.tick)
        try:                                           # `live --toggle`, or another instance, sends SIGUSR1 = stop
            asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, self.flow.on_stop)
        except (RuntimeError, NotImplementedError, ValueError):
            pass
        self.flow.start()

    # ------------------------------------------------------------ user actions: keys and buttons go to the flow
    def action_stop(self) -> None:
        self.flow.on_stop()

    def action_yes(self) -> None:
        self.flow.on_yes()

    def action_no(self) -> None:
        self.flow.on_no()

    def action_start(self) -> None:
        self.flow.on_start()

    def action_again(self) -> None:
        self.flow.on_again()

    def action_close(self) -> None:
        self.flow.on_close()

    def action_append(self) -> None:
        self.flow.on_claude("append")

    def action_send(self) -> None:
        self.flow.on_claude("send")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        {"start": self.flow.on_again, "stop": self.flow.on_stop, "copy": self.flow.on_yes,
         "append": lambda: self.flow.on_claude("append"), "send": lambda: self.flow.on_claude("send"),
         "new": self.flow.on_again, "close": self.flow.on_close, "stopit": self.flow.on_stop_it,
         "cancel": self.flow.on_cancel}[event.button.id]()
