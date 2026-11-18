# stenographr

@.hyperbeam/RULES.md

Local speech-to-text (Python): transcribe clips, dictate notes, `live` capture. Installed with
`uv tool install --editable .`, so `stenographr` is on PATH. Runs locally; no network at runtime (models are
downloaded once, by hand). Read the SPEC.md section for what you change, and update it when behaviour changes.

## Which file holds what
| Path | What it is |
|---|---|
| `src/stenographr/__init__.py` | Package marker (no code) |
| `src/stenographr/cli.py` | Entry point: clip, srt, notes, live, recall, phone, keybinding, update, `--version` |
| `src/stenographr/config.py` | Defaults + `~/.config/stenographr/config.toml` overrides |
| `src/stenographr/engines/` | Engine interface (`transcribe(audio) -> segments`) and implementations; `nemotron.py` is the streaming preview model of `live` |
| `src/stenographr/runner.py`, `device.py` | One engine per device per run; CPU/GPU choice with GPU->CPU fallback |
| `src/stenographr/clip.py`, `srt.py` | Clip extraction, `.txt` writing, archive naming (`archive_rel`), manifest; `.txt` -> `.srt` |
| `src/stenographr/dictate.py` | `_live`, the one streaming loop used by `notes` and `live`; `notes` |
| `src/stenographr/live.py` | `LiveSession` (one capture: record, clean pass, deliver), `run` |
| `src/stenographr/live_popup.py` | `live --toggle` (`toggle`), `raise_popup`, `_keep_on_top`, `stop_other`, `detect_where`; the popup's title and window class |
| `src/stenographr/live_state.py` | The live screen's state in one place: `Phase` enum, `TRANSITIONS` (an illegal move raises with STENO_STRICT=1, else is logged and ignored), live lines + partial |
| `src/stenographr/live_flow.py` | `LiveFlow`: the only thing that moves the state (start, record -> clean -> review, deliver); no Textual |
| `src/stenographr/live_ui.py` | The Textual screen (view only): draws what the flow says, passes keys and buttons to it |
| `src/stenographr/daily.py`, `recall.py` | Session blocks in the daily/notes files (writer, `block_text` for whole blocks, parser); `recall` (read-only) |
| `src/stenographr/record.py`, `audio.py` | `pw-record` command and mic checks; session Opus audio |
| `src/stenographr/phone.py`, `phone_page.py`, `phone_ctl.py` | `phone`: web server on 127.0.0.1 (upload -> `audio/` -> worker queue -> daily block), the one-screen page + manifest + icons, `--install`/`--remove` (systemd user service) and `--tailscale` |
| `src/stenographr/tmuxsend.py`, `clipboard.py`, `registry.py` | Send into the Claude pane; `wl-copy`; the one-recorder-at-a-time registry |
| `src/stenographr/keybind.py`, `update.py`, `log.py` | GNOME Ctrl+` binding; `update`; `<archive>/steno.log` |
| `scripts/get-models.sh` | Downloads the three models (VAD, Parakeet, Nemotron): sizes, skips what exists, asks first; the only network use |
| `docs/audio-setup.md` | Scarlett/WirePlumber setup |
| `SPEC.md` | Behaviour spec: layout, formats, what is built and open |
| `docs/decisions/` | One file per design decision; `docs/DECISIONS.md` is its generated index, never edited by hand |
| `docs/img/`, `docs/make-media.sh` | README pictures (GIF, PNGs) and the script that regenerates them in the lab (fake engine, fakes from `tests/fakebin`; writes only under `docs/img`) |
| `IDEAS.md` | Open / Done ideas |
| `tests/` | `run-tests.sh` (runs `tests/sections/*.sh` in parallel; helpers in `lib.sh`, `lib-dictation.sh`); fakes in `tests/fakebin/` (and `tests/fakeupd/` for `update`) plus a fake engine |
| `bench/` | Benchmark script (real data, outputs to /tmp only) |
| `system/wireplumber/` | WirePlumber rule for the two Scarlett interfaces (setup in `docs/audio-setup.md`) |

## Tests
`hyperbeam lab run --why "stenographr tests" -- bash tests/run-tests.sh`. Offline: no model, GPU, network, Docker, ports,
`/data` or real config/archive; fakes are first on PATH and never touch real GNOME settings, clipboard, tmux, kitty or PipeWire.
If no python with numpy and textual is found, the script makes a gitignored `.venv` with uv.
One file per section in `tests/sections/` (own temp dir, fakes and registry; shared helpers in `tests/lib.sh`, and
`tests/lib-dictation.sh` for the live/notes sections). `run-tests.sh` runs them all in parallel (~25 s), prints each
section's result and exits 1 listing the failed sections. Run one alone with `tests/run-tests.sh live-ui` (output live;
`env STENO_TEST_DEBUG=1` adds the daily file, ui output and log tail on a failure). A new section is a new file there;
sections must not depend on each other's state.
New checks must fail on the code they guard.

## Rules (details in SPEC.md)
- Transcripts are `.txt`, never `.md`. `clip` never overwrites a transcript (refuses, prints the `rm`, exit 1). Archive folders are flat.
- Timestamps `[HH:MM:SS]` go only in the daily/notes files, never in terminal output, typed text, clipboard or recall output.
- Session audio in `<archive>/audio/` is never deleted or overwritten; an audio failure never stops a session.
- Record only from the configured mic node; only one instance records at a time. `live` never types into other windows except a Claude pane via `tmux send-keys -l`; **Claude send** is the ONLY place Enter is pressed.
- Load the engine once per device per run (`Engines`), once per session for `notes`; `phone` loads it per burst of notes and drops it when the queue is empty. Don't hardcode Parakeet outside its engine module.
- `notes`, `live` and `phone` default to the CPU; `clip` stays auto. GPU: if enabling it needs sudo, a system CUDA install or >~2 GB of downloads, stop and report.
- Read-only on `/data` except benchmark outputs (`/tmp/stenographr-bench`). Don't modify phone-dock unless the task says so.
- Keep the repo publishable: no media, transcripts, logs, models, or personal paths/emails in files.
- Design decisions: `docs/decisions/YYYY-MM-DD-slug.md` (format in RULES.md). SPEC.md stays the behaviour spec.

## Git
One branch per task (`feat/`, `fix/`, `chore/<name>`), PR against `main` with `gh`; never commit to `main`.
PR descriptions end with a manual test checklist of real commands.
