"""The state of one live session in one place: the phases, the transitions that are allowed, and the text on screen.

The screen (live_ui.py) only renders this state and sends user actions; the flow (live_flow.py) is the only thing
that changes it. A transition that is not in TRANSITIONS raises when STENO_STRICT=1 (the tests), so a wrong move is a
loud bug there; otherwise it is logged as a warning and ignored: a bug must never crash the app someone is dictating
with (a crash loses their words).

  starting -> ready (loop) | notice | recording (popup) | error
  ready -> notice | recording | ready (cannot record: back to ready with a message)
  notice -> ready | recording | error
  recording -> stopping | cleaning | error          stopping -> cleaning | error
  cleaning -> review                                 review -> ready | picking | error
  picking -> review                                  error: the end (Close)
A popup never visits `ready`; Close / any popup choice exits the app from `review`, `ready` or `error`.
"""
from __future__ import annotations

import os
from enum import Enum


class Phase(str, Enum):
    """A str, so `phase == "ready"` keeps working in the tests."""
    STARTING = "starting"
    READY = "ready"            # loop only: waiting for Start
    NOTICE = "notice"          # another instance is recording: stop it and record here?
    RECORDING = "recording"
    STOPPING = "stopping"      # Stop pressed; the loop is flushing the last line
    CLEANING = "cleaning"      # the clean pass
    REVIEW = "review"          # the buttons: Copy / Append / Send / New / Close
    PICKING = "picking"        # choosing which Claude session to send to
    ERROR = "error"

    def __str__(self) -> str:
        return self.value


P = Phase
TRANSITIONS: dict[Phase, frozenset[Phase]] = {
    P.STARTING: frozenset({P.READY, P.NOTICE, P.RECORDING, P.ERROR}),
    P.READY: frozenset({P.READY, P.NOTICE, P.RECORDING}),
    P.NOTICE: frozenset({P.READY, P.RECORDING, P.ERROR}),
    P.RECORDING: frozenset({P.STOPPING, P.CLEANING, P.ERROR}),
    P.STOPPING: frozenset({P.CLEANING, P.ERROR}),
    P.CLEANING: frozenset({P.REVIEW}),
    P.REVIEW: frozenset({P.READY, P.PICKING, P.ERROR}),
    P.PICKING: frozenset({P.REVIEW}),
    P.ERROR: frozenset(),
}
LIVE_TEXT = (P.RECORDING, P.STOPPING)      # phases in which live lines and the partial are shown


class IllegalTransition(Exception):
    pass


class LiveState:
    """The phase plus the live text of the capture in progress."""

    def __init__(self, log=None) -> None:
        self.log = log                         # the app log (Log): where an ignored illegal move is reported
        self.phase = P.STARTING
        self.lines: list[str] = []             # finished live lines
        self.partial = ""                      # the line in progress

    def go(self, new: Phase) -> bool:
        """Move to `new`. An illegal move raises with STENO_STRICT=1, else it is logged and ignored (returns False)."""
        if new not in TRANSITIONS[self.phase]:
            if os.environ.get("STENO_STRICT") == "1":
                raise IllegalTransition(f"{self.phase} -> {new}")
            if self.log:
                self.log.warn("live", f"illegal phase move {self.phase} -> {new} ignored")
            return False
        self.phase = new
        return True

    def is_in(self, *phases: Phase) -> bool:
        return self.phase in phases

    def reset_text(self) -> None:
        self.lines, self.partial = [], ""

    def add_phrase(self, text: str) -> None:
        """A finished line. The partial on screen belonged to the line that just finished, so it goes with it: the
        next partial arrives as its own update (until then the old one would show as a duplicate line)."""
        self.lines.append(text)
        self.partial = ""

    def set_partial(self, text: str) -> bool:
        """The line in progress. Also while stopping: after Stop the loop flushes the last line and then clears the
        partial (""); dropping that update left the old partial under the finished line (shown twice).
        Returns whether the screen needs a redraw."""
        if self.phase in LIVE_TEXT:
            self.partial = text
            return True
        return False
