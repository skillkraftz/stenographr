# stenographr

Read SPEC.md before changing behaviour; update it when behaviour changes.

Local speech-to-text (Python). Installed with `uv tool install --editable .` so `stenographr` is on PATH
without activating a venv. Runs locally; no network at runtime (models are downloaded once, by hand).

## Layout
| Path | What it is |
|---|---|
| `src/stenographr/cli.py` | `stenographr clip|srt` entry point |
| `src/stenographr/config.py` | Defaults + `~/.config/stenographr/config.toml` overrides |
| `src/stenographr/engines/` | Engine interface (`transcribe(audio) -> segments`) and implementations |
| `src/stenographr/device.py` | CPU/GPU choice, checked before each file |
| `src/stenographr/clip.py` | ffmpeg extraction, .txt writing, archive naming (`archive_rel`), manifest line, recording-start logic |
| `src/stenographr/srt.py` | .txt -> .srt |
| `src/stenographr/runner.py` | `Engines` (one engine per device per run) and the CPU/GPU decision with GPU->CPU fallback |
| `src/stenographr/daily.py` | Session blocks in the daily/notes files (writer) and their parser |
| `src/stenographr/dictate.py` | `_live` (the one streaming loop, used by notes and live), `notes` |
| `src/stenographr/live.py` | `live`: session core (record, clean pass, Copy/Claude/none, end line), `live --toggle`, running-session marker |
| `src/stenographr/live_ui.py` | The Textual live screen (view only) |
| `src/stenographr/tmuxsend.py` | Find the Claude pane with tmux and `send-keys -l` into it (never Enter; no hyperbeam import) |
| `src/stenographr/record.py` | Mic node check, `pw-record` command (48 kHz), channel pick, `Down3` (48->16 kHz) |
| `src/stenographr/audio.py` | Session audio: ffmpeg Opus encoder fed while recording, file naming |
| `src/stenographr/recall.py` | `recall [N]` (read-only) |
| `src/stenographr/keybind.py` | The GNOME Ctrl+` keybinding (touches only its own entry) |
| `src/stenographr/log.py` | `<archive>/steno.log` |
| `SPEC.md` | The spec: layout, formats, what is built and what is open |
| `tests/` | `run-tests.sh`; fakes in `tests/fakebin/` (nvidia-smi, ffmpeg (clip extraction and the Opus encoder), ffprobe, pw-record, pw-dump, wl-copy, gsettings, tmux, kitty) and a fake engine |
| `bench/` | Benchmark script (real data, outputs to /tmp only) |

## Tests
`bash tests/run-tests.sh` (offline, no model, seconds). Fake `nvidia-smi` is first on PATH; the engine is a fake.
New checks must fail on the code they guard.

## Rules
- Tests never need a model, a GPU, the network, `/data`, or the user's real config/archive.
- Transcripts are `.txt`, never `.md`. One transcript per source file: `clip` refuses a video whose `<out>/<stem>.txt` or archive copy already exists (prints the `rm` to redo it, exit 1) and never overwrites or adds `-2`. Archive copy, flat folders: Samsung names `<archive>/clips/clip-YYYY-MM-DD-HHMMSS<suffix>.txt` (suffix = what follows the timestamp), anything else `<archive>/other/YYYY-MM-DD-<stem>.txt` (see `archive_rel`; never subfolders). A video with no audio stream gets a normal `.txt` whose body is `(no audio)`, so callers never retry it. (`srt` still uses `-2`, `-3` for now.)
- Daily manifest `<archive>/steno-YYYY-MM-DD.txt` (date = today), append only: one line per file `clip` handled (success, `FAILED: see steno.log`, `refused: already transcribed`). A manifest write failure is logged and never fails the run.
- Load the engine once per device per run (`Engines` in `runner.py`), never per file; `notes` loads it once per session.
- Dictation: `notes` and `live` use `dictate._live` (recorder starts first and is read by a thread, so audio during the model load is kept). Timestamps `[HH:MM:SS]` (recording start + offset) go only in the daily/notes files, never in terminal output, typed text, clipboard or recall output. Session audio goes to `<archive>/audio/` and is never deleted or overwritten; an audio failure never stops a session (start line `audio: none`, end line `ok (audio FAILED, see steno.log)`). In a git repo, notes go to `<repo root>/steno/`. Record only from the configured mic node (never fall back to another input); `live` never types into other windows (no ydotool): it copies to the clipboard or types one line into a Claude pane with `tmux send-keys -l`, and never presses Enter; `recall` only reads the daily files; the GNOME keybinding code never touches entries that aren't its own. Tests never touch the real GNOME settings, clipboard, tmux, kitty or PipeWire (fakes on PATH).
- Read-only on `/data` except explicit benchmark outputs (which go to `/tmp/stenographr-bench`).
- Do not modify phone-dock unless the task says so (then on its own branch in that repo).
- Engine and model are chosen in config; don't hardcode Parakeet outside its engine module.
- GPU: if enabling it needs sudo, a system CUDA install, or >~2 GB of downloads, stop and report.
- Keep the repo publishable: no media, transcripts, logs, models, or personal paths/emails in files.

## Git workflow
- One branch per task: `feat/`, `fix/` or `chore/<short-name>`. Commit, push, open a PR against `main` with `gh`.
- Never commit directly to `main`. Never force-push `main`.
- Always end the report with the branch name and the PR URL.
