# stenographr

Local speech-to-text (Python). Installed with `uv tool install --editable .` so `stenographr` is on PATH
without activating a venv. Runs locally; no network at runtime (models are downloaded once, by hand).

## Layout
| Path | What it is |
|---|---|
| `src/stenographr/cli.py` | `stenographr clip|srt` entry point |
| `src/stenographr/config.py` | Defaults + `~/.config/stenographr/config.toml` overrides |
| `src/stenographr/engines/` | Engine interface (`transcribe(audio) -> segments`) and implementations |
| `src/stenographr/device.py` | CPU/GPU choice, checked before each file |
| `src/stenographr/clip.py` | ffmpeg extraction, .md writing, naming, recording-start logic |
| `src/stenographr/srt.py` | .md -> .srt |
| `src/stenographr/log.py` | `<archive>/steno.log` |
| `tests/` | `run-tests.sh`; fakes in `tests/fakebin/` (nvidia-smi) and a fake engine |
| `bench/` | Benchmark script (real data, outputs to /tmp only) |

## Tests
`bash tests/run-tests.sh` (offline, no model, seconds). Fake `nvidia-smi` is first on PATH; the engine is a fake.
New checks must fail on the code they guard.

## Rules
- Tests never need a model, a GPU, the network, `/data`, or the user's real config/archive.
- Never overwrite an output file; add `-2`, `-3`.
- Read-only on `/data` except explicit benchmark outputs (which go to `/tmp/stenographr-bench`).
- Do not modify phone-dock.
- Engine and model are chosen in config; don't hardcode Parakeet outside its engine module.
- GPU: if enabling it needs sudo, a system CUDA install, or >~2 GB of downloads, stop and report.
- Keep the repo publishable: no media, transcripts, logs, models, or personal paths/emails in files.

## Git workflow
- One branch per task: `feat/`, `fix/` or `chore/<short-name>`. Commit, push, open a PR against `main` with `gh`.
- Never commit directly to `main`. Never force-push `main`.
- Always end the report with the branch name and the PR URL.
