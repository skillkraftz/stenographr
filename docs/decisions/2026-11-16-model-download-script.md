---
id: 2026-11-16-model-download-script
status: implemented
topic: models
prs: []
---
# A script downloads the models; the README only calls it

- **Decision:** `scripts/get-models.sh` fetches the three models (Silero VAD, Parakeet, Nemotron streaming) into the models folder. It prints each size, skips what is already there, asks before downloading (`-y` to skip the question; without a terminal and without `-y` it refuses), and checks a sha256 when one is set in its table (none are set yet, so it prints the hash it got). The README calls the script instead of listing the `curl` lines.
- **Why:** the three commands were copied by hand on every new machine, re-downloaded things that existed, and said nothing about size (Nemotron is about 0.5 GB). Models stay a manual, once-only download, so stenographr itself still never touches the network at runtime.
- **Rejected:** downloading on first run from inside stenographr (a surprise network call and a surprise download size); shipping the models in the repo (the repo stays free of media and models).
