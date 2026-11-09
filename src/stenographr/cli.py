from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import time
from pathlib import Path

from . import clip as clipmod
from . import config as configmod
from . import device as devmod
from .engines import gpu_runtime_available, make_engine
from .log import Log
from .srt import write_srt


class Engines:
    """One engine per device per run: the model load is the slow part, so build lazily and reuse."""

    def __init__(self, cfg, log: Log):
        self.cfg, self.log = cfg, log
        self.built: dict[str, object] = {}
        self.failed: dict[str, Exception] = {}       # a device that could not be built stays failed for the run

    def get(self, device: str, name: str):
        if device in self.failed:
            raise self.failed[device]
        if device not in self.built:
            t0 = time.monotonic()
            try:
                self.built[device] = make_engine(self.cfg, device)
            except Exception as e:                   # noqa: BLE001
                self.failed[device] = e
                raise
            self.log.info(name, f"engine loaded: device={device} load={time.monotonic() - t0:.2f}s")
        return self.built[device]


def _q(path) -> str:
    return "'" + str(path).replace("'", "'\\''") + "'"


def _targets(video: Path, out_dir: Path, start: dt.datetime, how: str, cfg) -> list[Path]:
    return [out_dir / f"{video.stem}.txt", cfg.archive / clipmod.archive_rel(video, start, how)]


def _manifest(cfg, log: Log, video: Path, result: str) -> None:
    """Append one line to <archive>/steno-<today>.txt. A manifest failure is logged, never fatal."""
    now = dt.datetime.now()
    try:
        path = cfg.archive / f"steno-{now:%Y-%m-%d}.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(clipmod.manifest_line(now, clipmod.kind(video), video.stem, result))
    except OSError as e:
        log.error(video.name, f"could not write the daily manifest: {type(e).__name__}: {e}")


def _transcribe_one(cfg, log: Log, engines: Engines, video: Path, out_dir: Path, requested: str,
                    start: dt.datetime, how: str) -> None:
    name = video.name
    log.info(name, f"start: engine={cfg.engine}")
    duration = clipmod.probe_duration(video)
    if not clipmod.has_audio(video):
        txt = clipmod.render_text(video, start, duration, cfg.engine, "none", [], dt.datetime.now(), note="(no audio)")
        p1, p2 = _targets(video, out_dir, start, how, cfg)
        clipmod.write_exclusive(p1, txt)
        clipmod.write_exclusive(p2, txt)
        log.info(name, f"finish: no audio stream, wrote placeholder {p1} and {p2}")
        _manifest(cfg, log, video, f"→ {clipmod.archive_rel(video, start, how)}")
        print(p1)
        return
    audio = clipmod.extract_audio(video)

    decision = devmod.decide(cfg, requested, gpu_runtime_available(cfg.engine))
    device = decision.device
    log.info(name, f"device: {device} ({decision.reason})")

    segments = None
    while segments is None:
        try:
            engine = engines.get(device, name)
            t1 = time.monotonic()
            segments = engine.transcribe(audio)
        except Exception as e:                       # noqa: BLE001 - any engine failure
            if device == "gpu":
                log.error(name, f"GPU run failed, redoing on CPU: {type(e).__name__}: {e}")
                device = "cpu"
                continue
            raise
        t2 = time.monotonic()
    audio_s = len(audio) / clipmod.SR
    run = t2 - t1
    log.info(name, f"timing: device={device} audio={audio_s:.1f}s transcribe={run:.2f}s "
                   f"rtf={run / audio_s if audio_s else 0:.4f}")

    txt = clipmod.render_text(video, start, duration, cfg.engine, device, segments, dt.datetime.now())
    p1, p2 = _targets(video, out_dir, start, how, cfg)
    clipmod.write_exclusive(p1, txt)
    clipmod.write_exclusive(p2, txt)
    log.info(name, f"finish: {len(segments)} segments, recording start from {how}; wrote {p1} and {p2}")
    _manifest(cfg, log, video, f"→ {clipmod.archive_rel(video, start, how)}")
    print(p1)


def cmd_clip(args) -> int:
    cfg = configmod.load(args.config)
    log = Log(cfg.archive / "steno.log")
    engines = Engines(cfg, log)
    failed = 0
    for v in args.video:
        video = Path(v)
        try:
            if not video.is_file():
                raise FileNotFoundError(f"no such file: {video}")
            out_dir = Path(args.out).absolute() if args.out else video.absolute().parent
            start, how = clipmod.recording_start(video, args.recorded_at)
            have = [p for p in _targets(video, out_dir, start, how, cfg) if os.path.lexists(p)]
            if have:                                  # one transcript per source file: refuse, say how to redo
                failed += 1
                rm = "rm " + " ".join(_q(p) for p in have)
                log.warn(video.name, f"refused: already transcribed: {' '.join(map(str, have))}")
                _manifest(cfg, log, video, "· refused: already transcribed")
                print(f"stenographr: {video.name}: already transcribed ({' and '.join(map(str, have))}); "
                      f"to redo it: {rm}", file=sys.stderr)
                continue
            _transcribe_one(cfg, log, engines, video, out_dir, args.device or cfg.device, start, how)
        except Exception as e:                       # noqa: BLE001 - report and carry on with the next file
            failed += 1
            log.error(video.name, f"{type(e).__name__}: {e}")
            _manifest(cfg, log, video, "· FAILED: see steno.log")
            print(f"stenographr: {video.name}: {e}", file=sys.stderr)
    return 1 if failed else 0


def cmd_srt(args) -> int:
    src = Path(args.file)
    try:
        print(write_srt(src))
    except OSError as e:
        print(f"stenographr: {e}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="stenographr", description="Local speech-to-text")
    ap.add_argument("--config", help="config file (default ~/.config/stenographr/config.toml)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("clip", help="transcribe video file(s) to .txt")
    c.add_argument("video", nargs="+")
    c.add_argument("--out", help="directory for the .txt (default: the video's own folder)")
    c.add_argument("--recorded-at", help="'YYYY-MM-DD HH:MM[:SS]' (used when the file name has no timestamp)")
    c.add_argument("--device", choices=["cpu", "gpu", "auto"], help="default: config (auto)")
    c.set_defaults(fn=cmd_clip)
    s = sub.add_parser("srt", help="write FILE.srt next to FILE.txt")
    s.add_argument("file")
    s.set_defaults(fn=cmd_srt)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
