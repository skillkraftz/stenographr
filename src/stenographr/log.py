"""<archive>/steno.log: plain text, one line per event: `time level file message`."""
from __future__ import annotations

import datetime as dt
from pathlib import Path


class Log:
    def __init__(self, path: Path):
        self.path = path

    def _write(self, level: str, file: str, msg: str) -> None:
        msg = " ".join(str(msg).split())          # one line per event, always
        line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {level:<5} {file or '-'} {msg}\n"
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass  # never let logging kill a transcription

    def info(self, file: str, msg: str) -> None:
        self._write("INFO", file, msg)

    def warn(self, file: str, msg: str) -> None:
        self._write("WARN", file, msg)

    def error(self, file: str, msg: str) -> None:
        self._write("ERROR", file, msg)
