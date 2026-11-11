"""Keep the audio of a dictation session: mono 48 kHz Ogg/Opus, 96 kbps, encoded WHILE recording.

ffmpeg reads raw float32 from a pipe. Two flags make a cut-off file still playable: `-flush_packets 1` and a short
Ogg page duration (verified: an ffmpeg killed with SIGKILL leaves a file that plays up to ~0.3 s before the kill;
without them the file is empty). If stenographr itself dies, ffmpeg sees the pipe close and finishes the file.
A failure here never affects the session: it is logged, and the session says so in the daily file.
"""
from __future__ import annotations

import datetime as dt
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .log import Log
from .record import REC_RATE

BITRATE = "96k"


def pick_path(archive: Path, start: dt.datetime, mode: str) -> Path:
    """<archive>/audio/YYYY-MM-DD-HHMMSS-<mode>.opus (session start); never an existing name."""
    d = archive / "audio"
    n = 1
    while True:
        p = d / (f"{start:%Y-%m-%d-%H%M%S}-{mode}.opus" if n == 1 else f"{start:%Y-%m-%d-%H%M%S}-{mode}-{n}.opus")
        if not p.exists():
            return p
        n += 1


class Encoder:
    """Fed with mono float32 @ REC_RATE. `ok` turns False if anything goes wrong; writes then do nothing."""

    def __init__(self, path: Path, log: Log, name: str):
        self.path, self.log, self.name = path, log, name
        self.ok = True
        self.proc = None
        self.err = tempfile.TemporaryFile()              # ffmpeg's stderr: no file on disk; read into steno.log on failure
        self.q: queue.Queue = queue.Queue()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            self.proc = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-n", "-f", "f32le", "-ar", str(REC_RATE),
                 "-ac", "1", "-i", "-", "-c:a", "libopus", "-b:a", BITRATE, "-flush_packets", "1",
                 "-page_duration", "200000", str(path)],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=self.err, start_new_session=True)
            time.sleep(0.15)                             # a bad path/permissions/codec fails within this
            if self.proc.poll() is not None:
                self._fail(f"ffmpeg exited at start (rc {self.proc.returncode}): "
                           f"{self._stderr()}")
        except OSError as e:
            self._fail(f"{type(e).__name__}: {e}")
        if self.ok:
            self.thread = threading.Thread(target=self._pump, daemon=True)
            self.thread.start()

    def _stderr(self) -> str:
        try:
            self.err.seek(0)
            return self.err.read().decode(errors="replace").strip()[:300]
        except (OSError, ValueError):
            return ""

    def _fail(self, why: str) -> None:
        if self.ok:
            self.log.error(self.name, f"audio not saved ({self.path}): {why}")
        self.ok = False

    def _pump(self) -> None:
        while True:
            b = self.q.get()
            if b is None:
                break
            if not self.ok:
                continue                                 # keep draining so the producer never blocks
            try:
                self.proc.stdin.write(b)
            except (OSError, ValueError) as e:
                self._fail(f"write to ffmpeg failed: {type(e).__name__}: {e}")

    def write(self, mono: bytes) -> None:
        if self.ok:
            self.q.put(mono)

    def close(self) -> bool:
        """Finish the file (the encoder writes its end-of-stream). Returns True if the audio was saved."""
        try:
            return self._close()
        finally:
            self.err.close()

    def _close(self) -> bool:
        if self.proc is None:
            return False
        if hasattr(self, "thread"):
            self.q.put(None)
            self.thread.join(timeout=15)
        try:
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            rc = self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            rc = -9
        if rc != 0:
            self._fail(f"ffmpeg exited with {rc}: {self._stderr()}")
        return self.ok
