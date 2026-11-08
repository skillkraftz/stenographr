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


def _targets(video: Path, out_dir: Path, start: dt.datetime, cfg) -> list[Path]:
    return [out_dir / f"{video.stem}.md", cfg.archive / "clips" / f"{clipmod.archive_stem(start)}.md"]


def _transcribe_one(cfg, log: Log, engines: Engines, video: Path, out_dir: Path, requested: str,
                    start: dt.datetime, how: str) -> None:
    name = video.name
    log.info(name, f"start: engine={cfg.engine}")
    duration = clipmod.probe_duration(video)
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

    md = clipmod.render_md(video, start, duration, cfg.engine, device, segments, dt.datetime.now())
    p1, p2 = _targets(video, out_dir, start, cfg)
    clipmod.write_exclusive(p1, md)
    clipmod.write_exclusive(p2, md)
    log.info(name, f"finish: {len(segments)} segments, recording start from {how}; wrote {p1} and {p2}")
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
            have = [p for p in _targets(video, out_dir, start, cfg) if os.path.lexists(p)]
            if have:                                  # one transcript per source file: refuse, say how to redo
                failed += 1
                rm = "rm " + " ".join(_q(p) for p in have)
                log.warn(video.name, f"refused: already transcribed: {' '.join(map(str, have))}")
                print(f"stenographr: {video.name}: already transcribed ({' and '.join(map(str, have))}); "
                      f"to redo it: {rm}", file=sys.stderr)
                continue
            _transcribe_one(cfg, log, engines, video, out_dir, args.device or cfg.device, start, how)
        except Exception as e:                       # noqa: BLE001 - report and carry on with the next file
            failed += 1
            log.error(video.name, f"{type(e).__name__}: {e}")
            print(f"stenographr: {video.name}: {e}", file=sys.stderr)
    return 1 if failed else 0


def cmd_srt(args) -> int:
    md = Path(args.file)
    try:
        print(write_srt(md))
    except OSError as e:
        print(f"stenographr: {e}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="stenographr", description="Local speech-to-text")
    ap.add_argument("--config", help="config file (default ~/.config/stenographr/config.toml)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("clip", help="transcribe video file(s) to .md")
    c.add_argument("video", nargs="+")
    c.add_argument("--out", help="directory for the .md (default: the video's own folder)")
    c.add_argument("--recorded-at", help="'YYYY-MM-DD HH:MM[:SS]' (used when the file name has no timestamp)")
    c.add_argument("--device", choices=["cpu", "gpu", "auto"], help="default: config (auto)")
    c.set_defaults(fn=cmd_clip)
    s = sub.add_parser("srt", help="write FILE.srt next to FILE.md")
    s.add_argument("file")
    s.set_defaults(fn=cmd_srt)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
