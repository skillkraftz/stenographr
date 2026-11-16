# stenographr

@.hyperbeam/RULES.md

Local speech-to-text (Python): transcribe clips, dictate notes, `live` capture. Installed with
`uv tool install --editable .`, so `stenographr` is on PATH. Runs locally; no network at runtime (models are
downloaded once, by hand). Read the SPEC.md section for what you change, and update it when behaviour changes.

## Which file holds what
| Path | What it is |
|---|---|
| `src/stenographr/cli.py` | Entry point: clip, srt, notes, live, recall, keybinding, update, `--version` |
| `src/stenographr/config.py` | Defaults + `~/.config/stenographr/config.toml` overrides |
| `src/stenographr/engines/` | Engine interface (`transcribe(audio) -> segments`) and implementations; `nemotron.py` is the streaming preview model of `live` |
| `src/stenographr/runner.py`, `device.py` | One engine per device per run; CPU/GPU choice with GPU->CPU fallback |
| `src/stenographr/clip.py`, `srt.py` | Clip extraction, `.txt` writing, archive naming (`archive_rel`), manifest; `.txt` -> `.srt` |
| `src/stenographr/dictate.py` | `_live`, the one streaming loop used by `notes` and `live`; `notes` |
| `src/stenographr/live.py`, `live_ui.py` | `live` capture flow and the Textual screen (view only) |
| `src/stenographr/daily.py`, `recall.py` | Session blocks in the daily/notes files (writer + parser); `recall` (read-only) |
| `src/stenographr/record.py`, `audio.py` | `pw-record` command and mic checks; session Opus audio |
| `src/stenographr/tmuxsend.py`, `clipboard.py`, `registry.py` | Send into the Claude pane; `wl-copy`; the one-recorder-at-a-time registry |
| `src/stenographr/keybind.py`, `update.py`, `log.py` | GNOME Ctrl+` binding; `update`; `<archive>/steno.log` |
| `SPEC.md` | Behaviour spec: layout, formats, what is built and open |
| `docs/decisions/` | One file per design decision; `docs/DECISIONS.md` is its generated index, never edited by hand |
| `IDEAS.md` | Open / Done ideas |
| `tests/` | `run-tests.sh`; fakes in `tests/fakebin/` (and `tests/fakeupd/` for `update`) plus a fake engine |
| `bench/` | Benchmark script (real data, outputs to /tmp only) |
| `system/wireplumber/` | WirePlumber rule for the two Scarlett interfaces (see README) |

## Tests
`hyperbeam lab run --why "stenographr tests" -- bash tests/run-tests.sh`. Offline: no model, GPU, network, Docker, ports,
`/data` or real config/archive; fakes are first on PATH and never touch real GNOME settings, clipboard, tmux, kitty or PipeWire.
If no python with numpy and textual is found, the script makes a gitignored `.venv` with uv. It is one sequential
bash script (~90 s): its sections share fakes and state, so they run in order (this is why it is not run in parallel).
New checks must fail on the code they guard.

## Rules (details in SPEC.md)
- Transcripts are `.txt`, never `.md`. `clip` never overwrites a transcript (refuses, prints the `rm`, exit 1). Archive folders are flat.
- Timestamps `[HH:MM:SS]` go only in the daily/notes files, never in terminal output, typed text, clipboard or recall output.
- Session audio in `<archive>/audio/` is never deleted or overwritten; an audio failure never stops a session.
- Record only from the configured mic node; only one instance records at a time. `live` never types into other windows except a Claude pane via `tmux send-keys -l`; **Claude send** is the ONLY place Enter is pressed.
- Load the engine once per device per run (`Engines`), once per session for `notes`. Don't hardcode Parakeet outside its engine module.
- `notes` and `live` default to the CPU; `clip` stays auto. GPU: if enabling it needs sudo, a system CUDA install or >~2 GB of downloads, stop and report.
- Read-only on `/data` except benchmark outputs (`/tmp/stenographr-bench`). Don't modify phone-dock unless the task says so.
- Keep the repo publishable: no media, transcripts, logs, models, or personal paths/emails in files.
- Design decisions: `docs/decisions/YYYY-MM-DD-slug.md` (format in RULES.md). SPEC.md stays the behaviour spec.

## Git
One branch per task (`feat/`, `fix/`, `chore/<name>`), PR against `main` with `gh`; never commit to `main`.
PR descriptions end with a manual test checklist of real commands.
