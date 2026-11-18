"""`stenographr phone`: a small web server so a phone can dictate notes that land here like laptop dictation.

Listens on 127.0.0.1 only (tailscale serve is the way in, see phone_ctl.py). One screen (phone_page.py) records with
MediaRecorder and POSTs the raw recording to /api/notes. The server:

  1. saves the upload as it came (webm/opus, mp4/aac, ...) to <archive>/audio/YYYY-MM-DD-HHMMSS-phone.<ext> and
     answers at once; the page keeps its copy until that answer arrives (a retry with the same note id is harmless);
  2. queues it for ONE background worker, which converts with ffmpeg (clip.extract_audio), transcribes with the same
     engine and settings as laptop dictation (the clean pass, whole sentences) and appends one session block
     (`start: ... · phone · <title or unknown> · audio/<file>`) to <archive>/steno-YYYY-MM-DD.txt in ONE write.
  3. keeps each note's state in <archive>/phone/<id>.json (queued / working / done / failed), so a restart
     picks up what was still queued (a note whose block is already in the daily file is not written twice) and the
     page can show the text.

The model is loaded when a burst of notes starts and dropped when the queue is empty (see worker): on the CPU it takes
~1.2 s, and it would otherwise keep ~5 GB of RAM while the laptop is used for dictation.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import queue
import re
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import audio as audiomod
from . import clip as clipmod
from . import daily, phone_page
from .log import Log
from .runner import Engines, transcribe_audio

NAME = "phone"
HOST = "127.0.0.1"
_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
_EXT = {"audio/webm": "webm", "video/webm": "webm", "audio/mp4": "m4a", "video/mp4": "m4a", "audio/x-m4a": "m4a",
        "audio/aac": "aac", "audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav"}


def clean_title(raw: str) -> str:
    """The `where` field of the start line: one line, no ' · ' (that is the field separator)."""
    t = " ".join(raw.replace("·", "-").split())[:80]
    return t or "unknown"


def note_file(archive: Path, n: dict) -> Path:
    """<archive>/phone/YYYY-MM-DD/HH-MM-SS[-title-slug].txt: the same name every time for the same note."""
    start = dt.datetime.fromisoformat(n["start"])
    title = clean_title(n["title"])
    slug = "" if title == "unknown" else re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40].strip("-")
    return archive / "phone" / f"{start:%Y-%m-%d}" / (f"{start:%H-%M-%S}-{slug}.txt" if slug else f"{start:%H-%M-%S}.txt")


def note_text(archive: Path, n: dict) -> str:
    start = dt.datetime.fromisoformat(n["start"])
    title = clean_title(n["title"])
    head = [f"{start:%Y-%m-%d %H:%M:%S}"] + ([] if title == "unknown" else [title]) + [daily.fmt_dur(n["seconds"]), str(archive / n["audio"])]
    return " · ".join(head) + "\n\n" + n["text"].strip() + "\n"


def write_note_file(archive: Path, n: dict) -> bool:
    """Write the note's text file atomically (temp file, then a hard link that fails if the name exists). False if it already existed."""
    dest = note_file(archive, n)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.parent / f".{dest.name}.tmp"
    tmp.write_text(note_text(archive, n), encoding="utf-8")
    try:
        os.link(tmp, dest)
        return True
    except FileExistsError:
        return False
    finally:
        tmp.unlink(missing_ok=True)


class Store:
    """Notes on disk (<archive>/phone/<id>.json) and the queue for the worker."""

    def __init__(self, cfg, log: Log, requested: str):
        self.cfg, self.log, self.requested = cfg, log, requested
        self.dir = cfg.archive / "phone"
        self.q: queue.Queue = queue.Queue()
        self.lock = threading.Lock()                     # file names and the notes dict
        self.notes: dict[str, dict] = {}
        self.dir.mkdir(parents=True, exist_ok=True)
        for f in sorted(self.dir.glob("*.json")):
            try:
                n = json.loads(f.read_text())
                self.notes[n["id"]] = n
            except (OSError, ValueError, KeyError):
                self.log.error(NAME, f"unreadable note state {f.name}: ignored")
        for n in sorted(self.notes.values(), key=lambda n: n["start"]):
            if n["status"] in ("queued", "working"):     # the server stopped before it finished: do it again
                n["status"] = "queued"
                self.q.put(n["id"])

    def _save(self, n: dict) -> None:
        tmp = self.dir / f".{n['id']}.tmp"
        tmp.write_text(json.dumps(n), encoding="utf-8")
        os.replace(tmp, self.dir / f"{n['id']}.json")

    def update(self, nid: str, **kw) -> None:
        with self.lock:
            n = self.notes[nid]
            n.update(kw)
            try:
                self._save(n)
            except OSError as e:
                self.log.error(nid, f"could not save the note state: {type(e).__name__}: {e}")

    def add(self, nid: str, tmp: Path, ctype: str, title: str, seconds: float) -> dict:
        """The upload is complete in `tmp`: give it its place in audio/, record it, queue it. Idempotent per id."""
        with self.lock:
            if nid in self.notes:                        # the page retried an upload that had in fact arrived
                tmp.unlink(missing_ok=True)
                return self.notes[nid]
            start = dt.datetime.now().replace(microsecond=0) - dt.timedelta(seconds=int(seconds))
            ext = _EXT.get(ctype, "audio")
            (self.cfg.archive / "audio").mkdir(parents=True, exist_ok=True)
            while True:
                dest = audiomod.pick_path(self.cfg.archive, start, NAME, ext)
                try:
                    os.link(tmp, dest)                   # fails if the name was taken meanwhile: never overwrite
                    break
                except FileExistsError:
                    start += dt.timedelta(seconds=1)
            tmp.unlink()
            n = {"id": nid, "start": start.isoformat(), "title": title, "seconds": seconds,
                 "audio": f"audio/{dest.name}", "status": "queued", "text": "", "error": ""}
            self.notes[nid] = n
            self._save(n)
        self.log.info(nid, f"upload saved: {n['audio']} ({dest.stat().st_size} bytes), queued")
        self.q.put(nid)
        return n

    def write_file(self, nid: str) -> None:
        try:
            write_note_file(self.cfg.archive, self.notes[nid])
        except OSError as e:
            self.log.error(nid, f"could not write the note's text file: {type(e).__name__}: {e}")

    def backfill(self) -> int:
        """A text file for every done note that has none. Never overwrites. Returns how many were written."""
        made = 0
        for n in sorted(self.notes.values(), key=lambda n: n["start"]):
            if n["status"] != "done":
                continue
            try:
                made += write_note_file(self.cfg.archive, n)
            except (OSError, ValueError) as e:
                self.log.error(n["id"], f"backfill: could not write the text file: {type(e).__name__}: {e}")
        if made:
            self.log.info(NAME, f"backfill: {made} text file(s) written")
        return made

    def today(self) -> list[dict]:
        day = f"{dt.date.today():%Y-%m-%d}"
        with self.lock:
            rows = [dict(n) for n in self.notes.values() if n["start"].startswith(day)]
        rows.sort(key=lambda n: n["start"])
        return [{"id": n["id"], "time": n["start"][11:16], "title": n["title"], "status": n["status"],
                 "text": n["text"], "error": n["error"]} for n in rows]

    # ---- the worker

    def work(self) -> None:
        engines: Engines | None = None
        while True:
            nid = self.q.get()
            if engines is None:
                engines = Engines(self.cfg, self.log)
            try:
                self._transcribe(nid, engines)
            except Exception as e:                       # noqa: BLE001 - one bad note never stops the queue
                self.log.error(nid, f"{type(e).__name__}: {e}")
                self._fail(nid, "transcription failed")
                engines = None                           # e.g. a model that failed to load gets a fresh try next time
            if self.q.empty():
                engines = None                           # burst over: free the model

    def _fail(self, nid: str, why: str) -> None:
        n = self.notes[nid]
        start = dt.datetime.fromisoformat(n["start"])
        self._append(start, daily.block_text(start, NAME, clean_title(n["title"]), n["audio"], [], n["seconds"], daily.failed(why)), nid)
        self.update(nid, status="failed", error=why)

    def _append(self, start: dt.datetime, text: str, nid: str) -> None:
        try:
            daily.append_line(daily.daily_path(self.cfg.archive, start), text)
        except OSError as e:
            self.log.error(nid, f"could not write the daily file: {type(e).__name__}: {e}")

    def _already_written(self, start: dt.datetime, n: dict) -> bool:
        """The server stopped after the block was appended but before the state was saved: take the block's result
        as the note's, do not write it again."""
        try:
            text = daily.daily_path(self.cfg.archive, start).read_text(encoding="utf-8")
        except OSError:
            return False
        for p in daily.parse_sessions(text):
            if p.mode == NAME and p.audio == n["audio"] and p.status is not None:
                failed = p.status.startswith("FAILED")
                self.update(n["id"], status="failed" if failed else "done", text="" if failed else p.text,
                            error="transcription failed" if failed else "")
                if not failed:
                    self.write_file(n["id"])
                self.log.info(n["id"], "already in the daily file: not written again")
                return True
        return False

    def _transcribe(self, nid: str, engines: Engines) -> None:
        n = self.notes[nid]
        self.update(nid, status="working")
        start = dt.datetime.fromisoformat(n["start"])
        if self._already_written(start, n):
            return
        audio = clipmod.extract_audio(self.cfg.archive / n["audio"])
        engines.decide(self.requested, NAME)
        segs, _ = transcribe_audio(self.cfg, self.log, engines, nid, audio, self.requested, method="transcribe_long")
        lines = [(start + dt.timedelta(seconds=s["start"]), s["text"].strip()) for s in segs if s["text"].strip()]
        seconds = len(audio) / clipmod.SR
        status = daily.ok(no_speech=not lines)
        self._append(start, daily.block_text(start, NAME, clean_title(n["title"]), n["audio"], lines, seconds, status), nid)
        self.update(nid, status="done", text=" ".join(t for _, t in lines), seconds=seconds)
        self.write_file(nid)
        self.log.info(nid, f"finish: {len(lines)} lines, {status}")


def make_handler(store: Store, max_bytes: int, version: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = 60

        def log_message(self, *a):                       # no access log on the terminal
            pass

        def _send(self, code: int, body: bytes, ctype: str, close: bool = False) -> None:
            try:
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                if close:
                    self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except OSError:                              # the phone went away (flaky connection): nobody to answer
                close = True
            if close:
                self.close_connection = True

        def _json(self, code: int, obj, close: bool = False) -> None:
            self._send(code, json.dumps(obj).encode(), "application/json", close)

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path == "/":
                html = phone_page.HTML.replace("/*NOTES*/[]", json.dumps(store.today()).replace("<", "\\u003c"))   # first paint has the list
                self._send(200, html.encode(), "text/html; charset=utf-8")
            elif path == "/manifest.webmanifest":
                self._send(200, phone_page.MANIFEST.encode(), "application/manifest+json")
            elif path in phone_page.ICONS:
                self._send(200, phone_page.icon(phone_page.ICONS[path]), "image/png")
            elif path == "/api/notes":
                self._json(200, store.today())
            elif path == "/version":
                self._send(200, version.encode(), "text/plain")
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            if urllib.parse.urlsplit(self.path).path != "/api/notes":
                return self._json(404, {"error": "not found"}, close=True)
            nid = self.headers.get("X-Note-Id", "")
            if not _ID.match(nid):
                return self._json(400, {"error": "bad or missing X-Note-Id"}, close=True)
            try:
                size = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._json(411, {"error": "Content-Length required"}, close=True)
            if size > max_bytes:
                return self._json(413, {"error": f"too large (max {max_bytes // 1024 // 1024} MB)"}, close=True)
            if size <= 0:
                return self._json(400, {"error": "empty upload"}, close=True)
            ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
            try:
                seconds = max(0.0, min(float(self.headers.get("X-Duration", "0")), 24 * 3600))
            except ValueError:
                seconds = 0.0
            title = urllib.parse.unquote(self.headers.get("X-Title", ""))[:200]
            tmp = store.dir / f".{nid}.{threading.get_ident()}.upload"
            got = 0
            try:
                with open(tmp, "wb") as f:
                    while got < size:
                        b = self.rfile.read(min(1 << 20, size - got))
                        if not b:
                            break
                        f.write(b)
                        got += len(b)
                    f.flush()
                    os.fsync(f.fileno())
                if got != size:                          # the connection broke: the page retries the whole thing
                    tmp.unlink(missing_ok=True)
                    return self._json(408, {"error": "incomplete upload"}, close=True)    # not 400: the page retries it
                n = store.add(nid, tmp, ctype, title, seconds)
            except OSError as e:
                store.log.error(nid, f"upload not saved: {type(e).__name__}: {e}")
                tmp.unlink(missing_ok=True)
                return self._json(500, {"error": "could not save the audio"}, close=True)
            self._json(200, {"id": n["id"], "status": n["status"]})

        def do_PUT(self): self._json(405, {"error": "method not allowed"}, close=True)
        do_DELETE = do_PATCH = do_PUT

    return Handler


def make_server(cfg, log: Log, requested: str, port: int | None = None, version: str = "unknown"):
    """(server, store); the worker thread is started here. The caller runs server.serve_forever()."""
    store = Store(cfg, log, requested)
    store.backfill()
    threading.Thread(target=store.work, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, cfg.phone_port if port is None else port),
                              make_handler(store, cfg.phone_max_mb * 1024 * 1024, version))
    srv.daemon_threads = True
    return srv, store


def backfill(cfg, log: Log) -> int:
    """`phone --backfill`: write the missing text files and exit."""
    made = Store(cfg, log, "cpu").backfill()
    print(f"phone: {made} text file(s) written in {cfg.archive / 'phone'}")
    return 0


def run(cfg, log: Log, requested: str, port: int | None, version: str) -> int:
    for f in cfg.archive.glob("phone/.*.upload"):        # an upload cut off by a restart; the page sends it again
        f.unlink(missing_ok=True)
    srv, store = make_server(cfg, log, requested, port, version)
    print(f"stenographr phone: listening on http://{HOST}:{srv.server_address[1]}  (Ctrl+C to stop)", flush=True)
    log.info(NAME, f"listening on {HOST}:{srv.server_address[1]}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0
