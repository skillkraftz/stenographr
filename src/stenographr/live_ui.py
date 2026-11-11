"""The live screen (Textual). 80x25 cells. It only shows text and buttons; it never types into other windows."""
from __future__ import annotations

import asyncio
import signal
import threading
import time

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, OptionList, RichLog, Static

from . import tmuxsend

BANNER = "Live preview · final text is cleaned up when you stop"


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
    #banner { height: 1; background: $primary; color: $text; padding: 0 1; }
    #status { height: 1; padding: 0 1; }
    #log { height: 1fr; padding: 0 1; }
    #buttons { height: 3; padding: 0 1; }
    #buttons Button { margin: 0 1 0 0; }
    PickSession { align: center middle; }
    #pick { width: 50; height: auto; max-height: 16; border: round $primary; background: $surface; padding: 1; }
    """
    BINDINGS = [Binding("s", "stop", "Stop"), Binding("y", "copy", "Copy"),
                Binding("c", "claude", "Send to Claude"), Binding("n", "nocopy", "Don't copy")]

    def __init__(self, session):
        super().__init__()
        self.session = session
        self.phase = "starting"        # recording | stopping | cleaning | review | picking | failed | error
        self.t_start = time.monotonic()
        self.claude_default: str | None = None
        self.claude_panes: dict[str, str] = {}

    # ------------------------------------------------------------ layout
    def compose(self) -> ComposeResult:
        yield Static(BANNER, id="banner")
        yield Static("", id="status")
        yield RichLog(id="log", wrap=True, markup=False, highlight=False)
        with Horizontal(id="buttons"):
            yield Button("Stop (s)", id="stop", variant="error")
            yield Button("Copy (y)", id="copy", variant="success")
            yield Button("Send to Claude (c)", id="claude", variant="primary")
            yield Button("Don't copy (n)", id="nocopy")

    def _show(self, *ids: str) -> None:
        for i in ("stop", "copy", "claude", "nocopy"):
            self.query_one(f"#{i}", Button).display = i in ids

    def _status(self, text: str) -> None:
        self.query_one("#status", Static).update(Text(text))

    # ------------------------------------------------------------ start
    def on_mount(self) -> None:
        self._show()
        err = self.session.preflight()
        if err:
            self.phase = "error"
            self._status(f"Cannot record: {err}")
            self.query_one("#nocopy", Button).label = "Close (n)"
            self._show("nocopy")
            return
        self.phase = "recording"
        self._show("stop")
        self.t_start = time.monotonic()
        self.set_interval(1.0, self._tick)
        self._tick()
        self.session.on_phrase = lambda t: self._post(self._add_phrase, t)
        try:                                           # `stenographr live --toggle` (Ctrl+`) sends SIGUSR1
            asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, self.action_stop)
        except (RuntimeError, NotImplementedError, ValueError):
            pass
        self.session.record_thread = threading.Thread(target=self._record_main, daemon=True)
        self.session.record_thread.start()

    def _post(self, fn, *args) -> None:
        try:
            self.call_from_thread(fn, *args)
        except Exception:                              # noqa: BLE001 - the app is already gone
            pass

    def _tick(self) -> None:
        if self.phase == "recording":
            s = int(time.monotonic() - self.t_start)
            self._status(f"● Recording {s // 60:02d}:{s % 60:02d} · stop: s, the button, or Ctrl+`")

    def _add_phrase(self, text: str) -> None:
        self.query_one("#log", RichLog).write(text)

    # ------------------------------------------------------------ record -> clean -> review
    def _record_main(self) -> None:
        self.session.record()
        self._post(self._recorded)

    def _recorded(self) -> None:
        if self.session.result is None:
            self.phase = "failed"
            self._status("Recording failed, see steno.log")
            self.query_one("#nocopy", Button).label = "Close (n)"
            self._show("nocopy")
            return
        self.phase = "cleaning"
        self._show()
        self._status("Cleaning up…")
        self.session.clean_thread = threading.Thread(target=self._clean_main, daemon=True)
        self.session.clean_thread.start()

    def _clean_main(self) -> None:
        try:
            self.session.clean()
        except Exception:                              # noqa: BLE001 - logged; the live text is used instead
            pass
        self._post(self._review)

    def _review(self) -> None:
        text = self.session.text()
        log = self.query_one("#log", RichLog)
        log.clear()
        if not text:
            self.phase = "review"
            self._status("No speech heard.")
            self.query_one("#nocopy", Button).label = "Close (n)"
            self._show("nocopy")
            return
        log.write(text)
        self._status("Clean-up failed: this is the live text (see steno.log)" if self.session.clean_failed
                     else "Clean text:")
        self.claude_default, self.claude_panes = tmuxsend.choose_target()
        claude = self.query_one("#claude", Button)
        if not self.claude_panes:
            claude.label, claude.disabled = "Send to Claude (no claude pane)", True
        elif self.claude_default:
            claude.label, claude.disabled = f"Send to Claude · {self.claude_default} (c)", False
        else:
            claude.label, claude.disabled = "Send to Claude… (c)", False
        self.phase = "review"
        self._show("copy", "claude", "nocopy")

    # ------------------------------------------------------------ actions (keys and buttons)
    def action_stop(self) -> None:
        if self.phase == "recording":
            self.phase = "stopping"
            self._status("Stopping…")
            self.session.request_stop()

    def action_copy(self) -> None:
        if self.phase == "review" and self.session.text():
            self._choose("copy")

    def action_nocopy(self) -> None:
        if self.phase == "review":
            self._choose("none")
        elif self.phase in ("failed", "error"):
            self.exit()

    def action_claude(self) -> None:
        if self.phase != "review" or not self.claude_panes or not self.session.text():
            return
        if self.claude_default:
            self._choose("claude", self.claude_default)
            return
        self.phase = "picking"

        def picked(session: str | None) -> None:
            self.phase = "review"
            if session:
                self._choose("claude", session)

        self.push_screen(PickSession(sorted(self.claude_panes)), picked)

    def _choose(self, choice: str, claude_session: str | None = None) -> None:
        status = self.session.deliver(choice, claude_session)
        if status.startswith("FAILED"):                # keep the text on screen so it can be copied by hand
            self.phase = "failed"
            self._status(status)
            self.query_one("#nocopy", Button).label = "Close (n)"
            self._show("nocopy")
        else:
            self.exit()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id
        if bid == "stop":
            self.action_stop()
        elif bid == "copy":
            self.action_copy()
        elif bid == "claude":
            self.action_claude()
        elif bid == "nocopy":
            self.action_nocopy()
