from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
from pathlib import Path

from . import clip as clipmod
from . import config as configmod
from .log import Log
from .runner import Engines, transcribe_audio
from .srt import write_srt
from . import dictate, keybind, live as livemod, recall as recallmod


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

    segments, device = transcribe_audio(cfg, log, engines, name, audio, requested)

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


def _cfg_log(args):
    cfg = configmod.load(args.config)
    return cfg, Log(cfg.archive / "steno.log")


def cmd_live(args) -> int:
    cfg, log = _cfg_log(args)
    if args.toggle:
        return livemod.toggle(cfg, log, args.config)
    return livemod.run(cfg, log, args.device or cfg.device, headless=args.headless)


def cmd_notes(args) -> int:
    cfg, log = _cfg_log(args)
    return dictate.notes(cfg, log, args.device or cfg.device)


def cmd_recall(args) -> int:
    cfg, _ = _cfg_log(args)
    return recallmod.recall(cfg.archive, args.n)


def cmd_keybinding(args) -> int:
    import shutil
    try:
        if args.action == "install":
            exe = shutil.which("stenographr")
            if not exe:
                print("stenographr: not on PATH, cannot build the command", file=sys.stderr)
                return 1
            path = keybind.install(f"{os.path.abspath(exe)} live --toggle")
            print(f"installed {keybind.NAME!r} ({keybind.BINDING}) at {path}")
        else:
            print("removed" if keybind.remove() else "not installed")
    except Exception as e:                               # noqa: BLE001
        print(f"stenographr: gsettings failed: {e}", file=sys.stderr)
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
    d = sub.add_parser("notes", help="live notes in this terminal until Ctrl+C")
    d.add_argument("--device", choices=["cpu", "gpu", "auto"], help="default: config (auto)")
    d.set_defaults(fn=cmd_notes)
    lv = sub.add_parser("live", help="live screen: phrases as you speak, clean text when you stop (never types)")
    lv.add_argument("--toggle", action="store_true",
                    help="Ctrl+`: stop the running live session, or open a kitty window with one")
    lv.add_argument("--device", choices=["cpu", "gpu", "auto"], help="default: config (auto)")
    lv.add_argument("--headless", action="store_true", help=argparse.SUPPRESS)      # tests: no terminal needed
    lv.set_defaults(fn=cmd_live)
    r = sub.add_parser("recall", help="copy a recent dictation back to the clipboard")
    r.add_argument("n", nargs="?", type=int, help="session number (skips the list)")
    r.set_defaults(fn=cmd_recall)
    k = sub.add_parser("keybinding", help="install/remove the Ctrl+` GNOME shortcut for live --toggle")
    k.add_argument("action", choices=["install", "remove"])
    k.set_defaults(fn=cmd_keybinding)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
