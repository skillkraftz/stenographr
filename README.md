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
stenographr clip VIDEO... [--out DIR] [--recorded-at "YYYY-MM-DD HH:MM"] [--device cpu|gpu|auto]
stenographr srt FILE.txt              # writes FILE.srt next to it (never automatic)
```

`clip` writes `DIR/<basename>.txt` (default `DIR`: the video's own folder) and an archive copy (flat folders, easy to
prune by hand):

- Samsung name: `<archive>/clips/clip-YYYY-MM-DD-HHMMSS<suffix>.txt`, the suffix being whatever follows the timestamp
  (`20251127_155055_001.mp4` -> `clip-2025-11-27-155055_001.txt`).
- Anything else: `<archive>/other/YYYY-MM-DD-<stem>.txt` (`some-talk.mp4` -> `other/<recording date>-some-talk.txt`).

A source file gets at most one transcript: if either file already exists, that video is refused (the message gives
the `rm` command to redo it), the other videos still run, and the exit code is 1. Nothing is ever overwritten. A
video with no audio stream gets a normal `.txt` whose only line is `(no audio)` (so it counts as done); one with audio
but no speech gets the header and no lines. The model is loaded once per run, however many videos are given.
(`srt` still adds `-2`, `-3` for now.)

Every file `clip` handles also adds one line to the day's manifest, `<archive>/steno-YYYY-MM-DD.txt` (today's date,
append only):

```
clip: 2026-11-09 08:37:05 · 20261109_083630 → clips/clip-2026-11-09-083630.txt
other: 2026-11-09 09:10:00 · some-talk → other/2026-11-08-some-talk.txt
clip: 2026-11-09 08:40:00 · 20261109_090000 · FAILED: see steno.log
clip: 2026-11-09 08:41:00 · 20261109_083630 · refused: already transcribed
```

The design is in [SPEC.md](SPEC.md). Transcript format:

```
# 20261108_063820 · recorded 2026-11-08 06:38 · 00:25:15
source: /path/to/20261108_063820.mp4
engine: parakeet-tdt-0.6b-v2-int8 (gpu) · transcribed 2026-11-08 10:17

[00:00:00 → 00:00:03 | 06:38:20] Alright, it's Sunday, November eighth.
```

The first two times are offsets into the video, the third is time of day. Recording start comes from a
Samsung file name (`YYYYMMDD_HHMMSS`, any suffix), else `--recorded-at`, else the file's mtime.

## Dictation

Needs `pw-record`, `ydotool` (user service running), `wl-copy`; records from the PipeWire node `scarlett-mic`
(see the audio section below), channel 1. Suggested aliases:

```sh
alias steno='stenographr notes'
alias recall='stenographr recall'
```

- `stenographr toggle` (Ctrl+`): the first press starts a background session that records at once and types each
  sentence at the cursor as you pause (sentence + a space). The second press finishes the last sentence, puts the
  whole session on the clipboard and ends the session. Everything is appended to the daily file as it is said.
- `stenographr notes` (`steno`): live in the terminal until Ctrl+C. Each sentence is printed, and appended at once
  to the notes file and to the daily file. Inside a git repo the notes file is `<repo root>/steno/steno-YYYY-MM-DD.txt`
  (and `steno/` is added to the repo's `.gitignore` if git isn't ignoring it yet); elsewhere it is
  `./steno-YYYY-MM-DD.txt`. The header line `stenographr notes · <folder>` is written when the file is created.
- `stenographr recall [N]` (`recall`): works on one daily file (today's, else the latest with anything in it). It
  prints `steno-DATE.txt: N pieces`, lists the newest 10 (sessions and clip/other lines), and asks which to copy: a
  number copies it, `a` lists all, Enter or `q` exits. `recall 2` copies piece 2 directly. A clip piece copies that
  transcript's text.

Every type and notes session also keeps its audio: `<archive>/audio/YYYY-MM-DD-HHMMSS-<mode>.opus` (mono, 48 kHz, Opus
96 kbps, about 0.7 MB per minute, encoded while recording so a crash still leaves it). The session's start line in the
daily file points to it; its time zero is the text's time zero. If the audio can't be saved the session still runs and
the start line says `audio: none`. Needs ffmpeg with libopus.

Only the kept records carry times: each sentence line in the daily and notes files starts with `[HH:MM:SS]` (when it
was said). The terminal output, typed text, clipboard and recall output never have them.

Block format (details in [SPEC.md](SPEC.md)):

```
start: 2026-11-09 10:00:00 · type · unknown · audio/2026-11-09-100000-type.opus
[10:00:03] <sentence>
[10:00:09] <sentence>
end: 2026-11-09 10:00:42 · 42s · ok
```

The microphone and channel are in `[dictation]` of the config (`mic = "scarlett-mic"`, `channel = 1`).

### Ctrl+` shortcut

```sh
stenographr keybinding install     # adds "stenographr dictation" = <Control>grave -> <path>/stenographr toggle
stenographr keybinding remove      # removes only that entry
```

By hand: Settings > Keyboard > View and Customize Shortcuts > Custom Shortcuts > +, name "stenographr dictation",
command = the output of `command -v stenographr` followed by ` toggle`, shortcut Ctrl+`. To undo, delete that entry
there. Note it is a global shortcut, so it takes Ctrl+` away from apps that use it (e.g. editors' terminal toggle).

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

## Audio: fixed names for the two Scarlett 2i2s

`system/wireplumber/51-scarletts.conf` is a WirePlumber 1.x rule file (not part of the Python package). The two
identical Scarlett 2i2s on the dock report the same serial, so WirePlumber told them apart only by a `.2` suffix
that depended on detection order, and after a replug the mic card could end up with no input. The file matches on
the USB product ID instead (the two cards are different models):

| Product ID | Card | Becomes |
|---|---|---|
| 1235:8016 | mic 2i2 (dock port 3.1.1) | device `scarlett-mic`, Pro Audio, input node `scarlett-mic` ("Scarlett mic"), default input via `priority.session` |
| 1235:8202 | main 2i2 (dock port 3.3.1) | device `scarlett-main`, profile HiFi, stays the default output |

Install (user config only, no sudo):

```sh
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
ln -s ~/projects/stenographr/system/wireplumber/51-scarletts.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

WirePlumber keys its saved settings (`~/.local/state/wireplumber/`) by device name, so after the rename any
old entries for `alsa_card.usb-Focusrite_Scarlett_2i2_USB-00[.2]` are stale; rename or remove them (and, if
you pick a default by hand, run `wpctl set-default` once). Check with `wpctl status`.

Undo: `rm ~/.config/wireplumber/wireplumber.conf.d/51-scarletts.conf`, then restart wireplumber. The match is the model, not the port, so the cards can move between dock ports;
it stops working if both cards are the same model (`lsusb | grep 1235` shows the IDs).
