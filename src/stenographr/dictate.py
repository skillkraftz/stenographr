"""Dictation: the one live loop (`_live`) shared by `notes` (terminal) and `live` (the Textual screen, live.py).

  notes  `stenographr notes`: sentences are printed in the terminal and appended to the notes file + the daily file.
  live   `stenographr live`: the live screen; it never types into other windows (see live.py).
"""
from __future__ import annotations

import datetime as dt
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import audio as audiomod
from . import daily
from .log import Log
from .record import Down3, channel_of, mic_exists, recorder_cmd
from .runner import Engines, pick_device


# ---------------------------------------------------------------- shared

def _fail_block(cfg, log: Log, name: str, mode: str, where: str, start: dt.datetime, reason: str) -> None:
    """A session that never got going still leaves a block in the daily file: the failure shows there first."""
    s = daily.Session(log, name, [(daily.daily_path(cfg.archive, start), None)], start, mode, where)
    s.end(dt.datetime.now(), daily.failed(reason))


def _copy(text: str) -> None:
    # wl-copy forks to serve the selection, so don't capture its output (the pipe would stay open)
    subprocess.run(["wl-copy"], input=text, text=True, timeout=10, check=True)


def _state_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/stenographr-{os.getuid()}"
    return Path(base) / "stenographr"


@dataclass
class LiveResult:
    status: str                                # ok / ok (no speech) / ok (audio FAILED...) / FAILED: ...; before delivery
    texts: list = field(default_factory=list)
    sess: "daily.Session | None" = None
    t0: "dt.datetime | None" = None
    audio_path: "Path | None" = None
    saved: bool = True
    pcm: "np.ndarray | None" = None            # the whole session at 16 kHz (only when asked): input of the clean pass
    engines: "Engines | None" = None


def _live(cfg, log: Log, requested: str, name: str, mode: str, where: str, targets, on_sentence,
          before_end=None, stop_event: "threading.Event | None" = None, signals: bool = True,
          finish: bool = True, keep_pcm: bool = False) -> LiveResult:
    """Record from the mic and turn speech into sentences as the speaker pauses.

    The audio is kept: recorded at 48 kHz, channel 1 only, encoded to Ogg/Opus while recording (audio.py), and
    decimated to 16 kHz for the VAD/model. Both come from the same samples, so the audio's time zero is the text's
    time zero (the first sample from the recorder).

    The recorder starts FIRST and a thread keeps reading it, so the audio spoken while the model loads is
    queued, not lost. Every sentence goes to the session files at once, as `[HH:MM:SS] text` (recording start
    + the sentence's offset into the audio), and to `on_sentence(text)` (no timestamp). SIGINT/SIGTERM (when
    `signals`) or `stop_event` finish the sentence in progress and end the recording. With `finish=False` the
    session block is left open (no end line) for the caller to add to. `before_end(texts)` may return problems
    (e.g. the clipboard failed) that go into the end line. Returns a LiveResult."""
    t0 = dt.datetime.now()
    stop = stop_event or threading.Event()

    if signals:                                          # main thread only (notes); `live` passes signals=False
        for sig in (signal.SIGINT, signal.SIGTERM):      # also overrides SIGINT=ignored (background jobs)
            signal.signal(sig, lambda *_: stop.set())

    _state_dir().mkdir(parents=True, exist_ok=True, mode=0o700)
    enc = audiomod.Encoder(audiomod.pick_path(cfg.archive, t0, mode), log, name, _state_dir() / f"{name}.audio.err")
    audio_ptr = f"audio/{enc.path.name}" if enc.ok else "audio: none"
    err = open(_state_dir() / f"{name}.err", "wb")
    proc = subprocess.Popen(recorder_cmd(cfg.mic, "-"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=err, start_new_session=True)
    q: queue.Queue = queue.Queue()

    def pump():
        fd = proc.stdout.fileno()
        while True:
            try:
                b = os.read(fd, 65536)
            except OSError:
                b = b""
            q.put(b or None)
            if not b:
                return

    threading.Thread(target=pump, daemon=True).start()
    sess = daily.Session(log, name, targets, t0, mode, where, audio_ptr)
    log.info(name, f"start: {where}, mic {cfg.mic} channel {cfg.channel}, {audio_ptr}")

    texts: list[str] = []
    pcm: list = []
    status = daily.ok()
    engines = Engines(cfg, log)

    def emit(segs):
        for s in segs:
            if not s["text"].strip():
                continue
            when = t0 + dt.timedelta(seconds=s["start"])
            sess.line(s["text"], when)
            texts.append(s["text"])
            on_sentence(s["text"])

    stream = None
    try:
        device = pick_device(cfg, log, name, requested)
        try:
            stream = engines.get(device, name).stream()
        except Exception as e:                           # noqa: BLE001
            if device != "gpu":
                raise
            log.error(name, f"GPU engine failed, using CPU: {type(e).__name__}: {e}")
            stream = engines.get("cpu", name).stream()

        rest, stopping, down = b"", False, Down3()
        while True:
            if stop.is_set() and not stopping:
                stopping = True                          # no more audio: stop the recorder (SIGTERM: pw-record flushes on it like on SIGINT, and it can never be inherited as ignored), drain what it sent
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except OSError:
                    pass
            try:
                b = q.get(timeout=0.2)
            except queue.Empty:
                if proc.poll() is not None and not stopping and q.empty():
                    log.error(name, f"pw-record exited unexpectedly (rc {proc.returncode})")
                    status = daily.failed("recorder exited")
                    break
                continue
            if b is None:                                # recorder's output closed
                if not stopping and not stop.is_set():
                    log.error(name, "pw-record closed its output unexpectedly")
                    status = daily.failed("recorder exited")
                break
            rest += b
            k = len(rest) // 8 * 8                       # whole stereo float32 frames only
            data, rest = rest[:k], rest[k:]
            mono = channel_of(data, cfg.channel)         # 48 kHz, the voice channel
            enc.write(mono.tobytes())
            small = down(mono)                           # 16 kHz, for the VAD/model
            if keep_pcm:
                pcm.append(small)
            emit(stream.accept(small))
        emit(stream.flush())                             # the sentence still in progress
    except Exception as e:                               # noqa: BLE001
        log.error(name, f"{type(e).__name__}: {e}")
        status = daily.failed("engine failed" if stream is None else "transcription error")
    finally:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    saved = enc.close()                                  # the encoder writes the end of the file
    if not saved and status.startswith("ok"):
        status = "ok (audio FAILED, see steno.log)"
    if finish:
        problems = before_end(texts) if before_end else []
        if status == daily.ok():
            status = daily.failed(", ".join(problems)) if problems else daily.ok(no_speech=not texts)
        sess.end(dt.datetime.now(), status)
        log.info(name, f"finish: {len(texts)} sentences, {status}")
    elif status == daily.ok() and not texts:
        status = daily.ok(no_speech=True)
    return LiveResult(status, texts, sess, t0, enc.path, saved,
                      np.concatenate(pcm) if pcm else (np.zeros(0, dtype=np.float32) if keep_pcm else None), engines)


# ---------------------------------------------------------------- notes

def _repo_root() -> Path | None:
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    except OSError:
        return None
    return Path(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else None


def _gitignore(log: Log, root: Path) -> None:
    """The steno/ folder must never get committed by accident: if git doesn't ignore it yet, append `steno/` to the
    repo root's .gitignore (and log it). Never commits anything."""
    try:
        if subprocess.run(["git", "check-ignore", "-q", "steno/x"], cwd=root).returncode != 1:
            return                                       # 0: already ignored; 128: git error: leave it alone
        gi = root / ".gitignore"
        old = gi.read_text() if gi.exists() else ""
        with open(gi, "a", encoding="utf-8") as f:
            f.write(("\n" if old and not old.endswith("\n") else "") + "steno/\n")
        log.info("notes", f"added steno/ to {gi}")
    except OSError as e:
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
    root = _repo_root()
    if root:                                             # in a git work tree: <repo root>/steno/, ignored by git
        _gitignore(log, root)
        home, notes_file = root, root / "steno" / f"steno-{start:%Y-%m-%d}.txt"
    else:
        home, notes_file = cwd, cwd / f"steno-{start:%Y-%m-%d}.txt"
    print(f"stenographr notes: listening on {cfg.mic}; Ctrl+C to stop", file=sys.stderr)
    res = _live(cfg, log, requested, name, "notes", str(notes_file),
                      [(daily.daily_path(cfg.archive, start), None),
                       (notes_file, f"stenographr notes · {home}")],
                      lambda text: print(text, flush=True))          # terminal: no timestamps
    return 0 if res.status.startswith("ok") else 1
