# stenographr: transcript backup and archive spec

Read this before changing behaviour; update it when behaviour changes. Lines marked
"(changed 2026-11-09)" were revised on that date. Status tags: BUILT / NOT BUILT.

## Purpose
The goal of the whole project: `/data/transcripts` must let me put everything back together: what was said,
when, where it went, and the audio it came from. The daily file `steno-YYYY-MM-DD.txt` is the single manifest.

Every transcription stenographr makes (from clips, notes or typing) is also copied to one known
location. That way I can see everything I dictated on a given day and copy text back out if
delivery fails. The archive is a backup: readable, copy-pasteable, no JSON in anything I read.
All transcripts and daily files are plain `.txt`, not `.md` (they are plain text, and `.md` opens in
Obsidian). (changed 2026-11-09)

## Layout (changed 2026-11-09)
```
/data/transcripts/                    archive root (configurable in ~/.config/stenographr/config.toml)
  steno-2026-11-09.txt                daily file, one per day, append only (clip lines and dictation sessions)
  steno.log                           error and event log, plain text
  clips/
    clip-2026-11-08-063820.txt        archive copy of a phone (Samsung-named) video's transcript
    clip-2025-11-27-155055_001.txt    the Samsung suffix is kept
  other/
    2026-11-08-some-talk.txt          any other video: <recording date>-<stem>
  audio/                              the audio of every dictation session (changed 2026-11-10)
    2026-11-09-112850-notes.opus      <session start>-<mode>.opus, mono 48 kHz Opus 96 kbps
    2026-11-09-113002-type.opus
```
- Files sit loose in the folder. The only subfolders are `clips/`, `other/` and `audio/`, all flat.
- Audio files are never deleted or overwritten by stenographr (a name collision gets `-2`).
- One transcript per source file: if either its `<stem>.txt` next to the video or its archive copy
  already exists, `clip` refuses that video, prints the `rm` command to redo it and exits 1. Nothing
  is ever overwritten and no `-2` is added. The daily file is append-only. (`srt` still writes `-2`,
  `-3`: open, see section 1.)

## 1. Clip transcripts (BUILT)
- Written next to the video: `<out>/<stem>.txt` (for phone-dock, `/data/footage/clips/<date>/<stem>.txt`,
  beside `<stem>.mp4`). (changed 2026-11-09)
- A copy goes to the archive: (changed 2026-11-09)
  - Samsung name (`YYYYMMDD_HHMMSS` then anything):
    `clips/clip-YYYY-MM-DD-HHMMSS<suffix>.txt`, where `<suffix>` is whatever follows the timestamp in the
    stem, as is (`20251127_155055_001.mp4` -> `clip-2025-11-27-155055_001.txt`).
  - Anything else: `other/YYYY-MM-DD-<stem>.txt`. The date is the recording start.
  The recording start is the Samsung file name, else `--recorded-at`, else the file's mtime.
- A video with no audio stream gets a normal transcript whose body is `(no audio)`, so callers never
  retry it. One with audio but no speech gets the header and no lines.
- Transcription runs on the original video from the phone backup, not the converted clip. It happens
  as part of phone-dock's clips menu: the selected originals are transcribed first, then encoded
  (switch: `TRANSCRIBE=1` in phone-dock's config). A failed transcript never blocks the clip. (BUILT;
  changed 2026-11-09)  Timestamps from the original match the clip within 2 ms, so the times line up.
- The model is loaded once per device per run, however many videos are given.
- Format (unchanged):
  ```
  # 20261108_063820 · recorded 2026-11-08 06:38 · 00:25:15
  source: /data/phone/videos/2026/11/20261108_063820.mp4
  engine: parakeet-tdt-0.6b-v2-int8 (cpu) · transcribed 2026-11-08 10:27

  [00:00:08 → 00:00:10 | 06:38:28] Sunday, November 8th.
  [00:00:30 → 00:00:34 | 06:38:50] I have my pills by my bedside for the morning.
  ```
  In each line, the first two times are positions in the video; the third is the time of day it
  was said. Times are whole seconds.
- `.srt` (for Kdenlive subtitle import) is NOT written automatically. `stenographr srt FILE.txt`
  generates `FILE.srt` next to it (the parser does not depend on the extension).
  **Open:** replace an existing `.srt` (recommended) or write `-2` (what it does now)?
- In the daily file, a clip gets a single pointer line, not its full text (see section 2).

## 2. Daily file: `steno-YYYY-MM-DD.txt`
A catch-all for everything stenographr did that day. The date is today, when the transcription ran
(not the recording date). Append only.

Clip and other pointer lines, one per file handled by `stenographr clip` (BUILT, 2026-11-09):
```
clip: 2026-11-09 08:37:05 · 20261109_083630 → clips/clip-2026-11-09-083630.txt
other: 2026-11-09 09:10:00 · some-talk → other/2026-11-08-some-talk.txt
clip: 2026-11-09 08:40:00 · 20261109_090000 · FAILED: see steno.log
clip: 2026-11-09 08:41:00 · 20261109_083630 · refused: already transcribed
```
The word before the time is `clip` for Samsung-named videos and `other` for the rest. The time is
when the line was written. If writing the manifest itself fails, that is logged to `steno.log`
and the run carries on (the transcript still counts).

Dictation sessions (BUILT 2026-11-09; timestamps added 2026-11-10; audio pointer added 2026-11-10), written by
`toggle` and `notes`:
```
start: 2026-11-09 10:00:00 · type · unknown · audio/2026-11-09-100000-type.opus
[10:00:03] <sentence>
[10:00:09] <sentence>
end: 2026-11-09 10:00:42 · 42s · ok
start: 2026-11-09 10:05:00 · notes · /home/andy/projects/hyperbeam/steno/steno-2026-11-09.txt · audio/2026-11-09-100500-notes.opus
[10:05:02] <sentence>
end: 2026-11-09 10:12:30 · 7m30s · ok
```
- **Audio pointer (changed 2026-11-10):** the last part of the start line is the session's audio file, relative to
  the archive root. If the audio could not be kept it reads `audio: none` and the end line says
  `ok (audio FAILED, see steno.log)`; the session itself still runs and delivers. A session that never got
  going (e.g. mic not found) has no audio part. Older files (no audio part) are still read by recall.
- **Where (changed 2026-11-10):** for notes it is the notes file's full path (not just the folder); for type
  it is the window, always `unknown`.
- **Audio time zero = text time zero:** the audio file starts at the first sample from the recorder, and the
  text timestamps are the recording start + each sentence's offset counted from that same sample, so
  `[HH:MM:SS] - start line time` is the position in the audio (to within the whole-second resolution of the
  stamps; verified against the real model).
- **Sentence lines carry a time of day (changed 2026-11-10):** `[HH:MM:SS]` = the recording start + the
  sentence's offset into the audio (when it started being said, not when it was transcribed). This is in
  the daily file and in the notes file, for both type and notes sessions. start/end lines and clip lines
  are unchanged. Timestamps are only in these kept records: never in the terminal output of `notes`, the
  text typed by `toggle`, the clipboard, or recall's output.
- The start line records when, which mode (`type` or `notes`) and where the text went: the window
  for typing, the absolute folder for notes. The window is always `unknown`: on GNOME Wayland without an
  extension the focused window's title cannot be read (`Shell.Eval` is disabled and
  `Introspect.GetWindows` is refused; verified 2026-11-09).
- The end line records when it ended, how long the recording was (`42s`, `7m30s`, `1h02m05s`) and the
  result: `ok`, `ok (no speech)`, or `FAILED: <short reason>, see steno.log` (mic not found, typing
  failed, clipboard failed, recorder exited, transcription error). A failure shows here first, with the
  details in `steno.log`.
- A session is everything from starting dictation to stopping it, not one block per phrase. Both modes
  append each sentence as it is spoken (changed 2026-11-10: type used to write its block at the end), so a
  crash leaves a block with no end line; recall still sees it (its text is the lines after its start).
  A session that never got going (e.g. mic missing) leaves a start/end pair with no text.

## 3. Error log (BUILT for clips): `steno.log`
- Plain text, one line per event: time, level, session or file, message. A single log; there is no
  separate `steno.err`. (changed 2026-11-09)
- It records starts and finishes, the device chosen and why, and every error with enough detail
  to understand what happened. Purpose: if I dictate and nothing shows up, this file says why.

## 4. recall (BUILT 2026-11-09; reworked 2026-11-10)
`stenographr recall [N]` (aliasable to `recall`). Read-only on every file. It works on the pieces of ONE
daily file: today's, or if that has no pieces, the most recent daily file that does.
- A **piece** is one session block (start..end, or start..end of file / next piece when the end line is
  missing) or one clip/other line. A session with no text (e.g. mic not found) is not a piece.
- Pieces are numbered newest first. The header names the file and the total: `steno-2026-11-09.txt: 23 pieces`.
  The list shows the newest 10, one line each: `N. [HH:MM] <mode> · <first ~60 characters>...` (the `...` only
  when cut). For a clip/other line the mode is `clip`/`other`, then the source name, then the start of that
  transcript's text (a line with no transcript, e.g. FAILED, shows what the line says).
  ```
  steno-2026-11-09.txt: 23 pieces
  1. [11:51] notes · Alright, it's Sunday, November eighth. Uh 740 to go to the b...
  2. [11:50] clip · 20261109_083630 · This is a test. This is a test. We are testing
  Which do you need to copy? (a = list all)
  ```
- At the prompt: a number from 1 to the total copies that piece; `a` lists all pieces with the same
  numbering and asks again; Enter or `q` exits without copying.
- What is copied is text only, never timestamps: a session's sentences joined with spaces; for a clip/other
  piece, the spoken text of that transcript file (no header, no time prefixes). If the transcript file is
  missing, it says so and copies nothing. `recalled:` and the full text are printed after copying.
- `recall N` copies piece N of that file without listing.

## 5. Dictation modes (BUILT 2026-11-09)
- **Clip:** section 1.
- **Type mode**, `stenographr toggle`, bound to Ctrl+` (live since 2026-11-10): the first press starts a
  background session (`stenographr _type-session`, detached, no terminal needed) and returns at once. The
  session starts the recorder FIRST and keeps reading it, then loads the model, so what is said while the
  model loads is queued and still transcribed. As soon as I pause, each sentence is typed at the cursor
  (`ydotool type`: the sentence plus one space) and appended to the daily file with its timestamp. The
  second press sends SIGTERM to the session: it finishes the sentence in progress, types it, puts the whole
  session's text (no timestamps) on the clipboard (`wl-copy`), writes the end line and exits. If typing
  fails the clipboard and the daily file still have everything, and the end line says FAILED. No speech:
  nothing typed or copied, `ok (no speech)`. State (the session pid) is in
  `$XDG_RUNTIME_DIR/stenographr/state`; a pid that is gone means start fresh. A detached process with no
  terminal keeps running and reaches Wayland and the ydotool socket through the session's
  `XDG_RUNTIME_DIR` (verified 2026-11-10).
- **Notes mode**, `stenographr notes` (aliasable to `steno`): runs in the terminal until Ctrl+C. Text
  appears sentence by sentence as I pause (Silero VAD fed live, 0.6 s of silence ends a sentence); each
  sentence is appended at once to the notes file and to the daily file (timestamped there; the terminal
  shows bare sentences). Notes and type share one streaming loop (`dictate._live`).
  **Notes file location (changed 2026-11-10):** inside a git work tree, `<repo root>/steno/steno-YYYY-MM-DD.txt`
  (`steno/` is created); anywhere else, `./steno-YYYY-MM-DD.txt` in the current folder. The file's first line,
  written only when it is created, is `stenographr notes · <absolute folder>` (the repo root, or the current
  folder); after that come the same start / sentences / end blocks. One file per day per place, append only.
  Ctrl+C finishes the sentence in progress, writes the end lines and exits 0. The model is loaded once.
  In a repo where `git check-ignore -q steno/x` says `steno/` is not ignored, the line `steno/` is appended
  to the repo root's `.gitignore` (and logged); nothing is ever committed. `steno/` is also in the global git
  ignore on this machine, so normally nothing needs adding.
- **Session audio (BUILT 2026-11-10)**, both modes: the mic is recorded at 48 kHz (`pw-record --rate 48000`,
  2 channels, float32), channel 1 (AUX0) is kept, and it is (a) streamed to ffmpeg's libopus encoder while
  recording: mono, 48 kHz, 96 kbps (about 0.7 MB per minute), to `<archive>/audio/YYYY-MM-DD-HHMMSS-<mode>.opus`
  (session start), and (b) decimated to 16 kHz for the VAD/model (a 63-tap low-pass + every third sample,
  `record.Down3`; no resampler library needed). The encoder uses `-flush_packets 1` and a 0.2 s Ogg page
  duration, so a file cut off mid-write (ffmpeg killed) still plays up to about 0.3 s before the cut; if
  stenographr itself dies, ffmpeg sees its input close and finishes the file. The audio is for tuning the
  live-typing latency and as background audio for screen recordings in Kdenlive.
- **Recording indicator:** GNOME's built-in mic icon in the top bar (verified: it appears with
  `pw-record`). No notifications.
- **Mic:** the WirePlumber config in `system/wireplumber` (PR #3) names the mic 2i2 `scarlett-mic`
  (matched by USB product ID 8016) and makes it the default input. stenographr records from that node
  (`[dictation] mic`), 16 kHz float32, 2 channels (AUX0/AUX1), and keeps channel 1 (`[dictation] channel`,
  AUX0: the voice; AUX1 is silent). The node is checked before recording; if it is missing nothing is
  recorded, the daily file gets `FAILED: mic scarlett-mic not found` and it is logged. Never another input.
- **Hotkey:** `stenographr keybinding install` adds a GNOME custom keybinding "stenographr dictation",
  `<Control>grave`, command = the absolute path of `stenographr` + ` toggle`; it appends to the existing
  list and never changes other entries. `stenographr keybinding remove` removes only that entry.
- Needs `pw-record`, `pw-dump`, `ffmpeg` (with libopus), `ydotool` (user service running), `wl-copy`, `git` (notes mode only).

## Other decisions
- Corrections file for mis-heard names: dropped (transcripts mostly go to AI, which infers meaning).
  (changed 2026-11-09)
- The CPU run used 4.9 GB of RAM, against about 800 MB for a comparable tool: later.
  (changed 2026-11-09)
