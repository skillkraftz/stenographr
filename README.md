# stenographr

Local speech-to-text. Runs entirely on this machine; nothing is uploaded.

Engine: NVIDIA Parakeet TDT 0.6B v2 (int8) through [sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/),
with Silero VAD to cut long recordings into utterances. CPU or GPU, chosen per file.

## Install

```sh
uv tool install --editable .          # CPU only; `stenographr` lands on PATH
uv tool install --editable ".[gpu]"   # + CUDA 13 sherpa-onnx and NVIDIA libs (~1.6 GB of wheels, no sudo)
```

Models are downloaded once, by hand, into `~/.local/share/stenographr/models`:

```sh
cd ~/.local/share/stenographr/models
curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2 | tar xj
```

## Use

```sh
stenographr clip VIDEO... --out DIR [--recorded-at "YYYY-MM-DD HH:MM"] [--device cpu|gpu|auto]
stenographr srt FILE.md               # writes FILE.srt next to it (never automatic)
```

`clip` writes `DIR/<basename>.md` and a copy at `<archive>/clips/clip-YYYY-MM-DD-HHMMSS.md`.
Existing files are never overwritten (`-2`, `-3`, ...). Format:

```
# 20261108_063820 · recorded 2026-11-08 06:38 · 00:25:15
source: /path/to/20261108_063820.mp4
engine: parakeet-tdt-0.6b-v2-int8 (gpu) · transcribed 2026-11-08 10:17

[00:00:00 → 00:00:03 | 06:38:20] Alright, it's Sunday, November eighth.
```

The first two times are offsets into the video, the third is time of day. Recording start comes from a
Samsung file name (`YYYYMMDD_HHMMSS`, any suffix), else `--recorded-at`, else the file's mtime.

## Device selection

Checked before each file with `--device auto`. The GPU is used only if `nvidia-smi` exists, a CUDA-enabled
sherpa-onnx is installed, free VRAM >= `vram_need_mib + vram_margin_mib`, GPU utilization is below
`max_gpu_util_pct`, and none of `busy_processes` is running (default: Kdenlive's render, `melt`/`melt-7`/
`kdenlive_render`). Otherwise CPU. If a GPU run fails the file is redone on the CPU.

## Config

`~/.config/stenographr/config.toml` (all keys optional):

```toml
[paths]
models  = "~/.local/share/stenographr/models"
archive = "/data/transcripts"

[engine]
name = "parakeet-tdt-0.6b-v2-int8"
num_threads = 8
batch_size = 0          # 0 = auto (GPU 1, CPU 8)

[device]
device = "auto"
vram_need_mib = 1000
vram_margin_mib = 500
max_gpu_util_pct = 30
busy_processes = ["melt", "melt-7", "kdenlive_render"]
```

## Log

`<archive>/steno.log`: one plain-text line per event: `time level file message` (start, device and why,
timing, finish, errors).

## Tests

`bash tests/run-tests.sh` (offline, no model; fake engine and fake `nvidia-smi`/`ffmpeg`/`ffprobe`).
