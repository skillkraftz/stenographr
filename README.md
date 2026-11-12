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
curl -L https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2 | tar xj   # live preview, ~0.5 GB download
```

## Use

```sh
stenographr clip VIDEO... [--out DIR] [--recorded-at "YYYY-MM-DD HH:MM"] [--device cpu|gpu|auto]
stenographr srt FILE.txt              # writes FILE.srt next to it (never automatic)
stenographr --version
stenographr update                    # from any directory: git pull --ff-only the source checkout (see below)
```

`update` prints the source path, branch, commit and how far it is ahead/behind `origin` (after a `git fetch`). It only
pulls when the checkout is on a clean `main` (never stashes, resets or switches branches), reruns
`uv tool install --editable ".[gpu]" --force` if `pyproject.toml` changed, and ends by listing the running
`stenographr live` instances (pid, popup or tmux pane) that need a restart. It never stops them.

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

Needs `pw-record`, `ffmpeg` (libopus), `wl-copy`, `kitty` (for the shortcut), `tmux` (only for the Claude buttons); records from the PipeWire node `scarlett-mic`
(see the audio section below), channel 1. Suggested aliases:

```sh
alias steno='stenographr notes'
alias recall='stenographr recall'
```

- `stenographr live`: a Textual screen that never types into other windows. It shows each phrase as you speak (and
  appends it to the daily file), and when you stop it re-transcribes the whole session in one pass to get whole
  sentences. Two kinds of instance, and several can be open at once:
  - **Loop** (`stenographr live` in a terminal or tmux pane): opens on **Ready** (mic closed). **Start** (Enter or `r`) ->
    recording -> **Stop** (`s`) -> clean text with **Copy (y)** (clipboard plus a trailing space, back to Ready), **Claude append (a)**
    (types the text plus a space into that tmux session's Claude Code input, no Enter, so you can append several takes) and
    **Claude send (e)** (types the text and presses Enter: submits everything in the input; the only Enter stenographr ever sends);
    both back to Ready. The session's name is at the right end of the blue bar. **New (r)**
    (nothing delivered, back to Ready) and **Close (q / Esc)**. Ready shows "Last: sent to claude alpha · 22:14". The model
    loads once per app. Each capture is its own session block and audio file.
  - **Popup** (opened by Ctrl+`, which runs `stenographr live --toggle`): a kitty window, 80x25, that records at once;
    Stop gives **Copy**, **Claude append**, **Claude send** and **Close**, then the window closes. Ctrl+` while a popup is recording stops
    it; otherwise it does nothing while a popup is open; it never touches loop instances.
  - **One recording at a time:** starting while another instance records shows "Recording in <where>. Stop it and record
    here?" (**Stop it and record here** / **Cancel**). Stop it makes the other instance stop and show its own clean text;
    it stays open.
  The buttons and text reflow with the pane size (a tall narrow sidebar works). Closing a window any other way stops it without delivering; the live lines and the audio are already saved.
- `stenographr notes` (`steno`): live in the terminal until Ctrl+C. Each sentence is printed, and appended at once
  to the notes file and to the daily file. Inside a git repo the notes file is `<repo root>/steno/steno-YYYY-MM-DD.txt`
  (and `steno/` is added to the repo's `.gitignore` if git isn't ignoring it yet); elsewhere it is
  `./steno-YYYY-MM-DD.txt`. The header line `stenographr notes · <folder>` is written when the file is created.
- `stenographr recall [N]` (`recall`): works on one daily file (today's, else the latest with anything in it). It
  prints `steno-DATE.txt: N pieces`, lists the newest 10 (sessions and clip/other lines), and asks which to copy: a
  number copies it, `a` lists all, Enter or `q` exits. `recall 2` copies piece 2 directly. A clip piece copies that
  transcript's text.

Every live and notes session also keeps its audio: `<archive>/audio/YYYY-MM-DD-HHMMSS-<mode>.opus` (mono, 48 kHz, Opus
96 kbps, about 0.7 MB per minute, encoded while recording so a crash still leaves it). The session's start line in the
daily file points to it; its time zero is the text's time zero. If the audio can't be saved the session still runs and
the start line says `audio: none`. Needs ffmpeg with libopus.

Only the kept records carry times: each sentence line in the daily and notes files starts with `[HH:MM:SS]` (when it
was said). The terminal output, live screen, clipboard, text sent to Claude and recall output never have them.

Block format (details in [SPEC.md](SPEC.md)):

```
start: 2026-11-10 20:06:00 · live · unknown · audio/2026-11-10-200600-live.opus
[20:06:01] <live phrase>
clean:
[20:06:01] <clean sentence or paragraph>
end: 2026-11-10 20:07:30 · 1m30s · ok · copied
```

The microphone and channel are in `[dictation]` of the config (`mic = "scarlett-mic"`, `channel = 1`).

### Ctrl+` shortcut

```sh
stenographr keybinding install     # adds "stenographr dictation" = <Control>grave -> <path>/stenographr live --toggle
stenographr keybinding remove      # removes only that entry
```

By hand: Settings > Keyboard > View and Customize Shortcuts > Custom Shortcuts > +, name "stenographr dictation",
command = the output of `command -v stenographr` followed by ` live --toggle`, shortcut Ctrl+`. To undo, delete that entry
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

`hyperbeam stenographr test` (runs `bash tests/run-tests.sh` in the lab; offline, no model; fake engine and fake `nvidia-smi`/`ffmpeg`/`ffprobe`).
If no python with numpy and textual is found, it makes a `.venv` with uv.

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
