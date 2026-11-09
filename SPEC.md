# stenographr: transcript backup and archive spec

Read this before changing behaviour; update it when behaviour changes. Lines marked
"(changed 2026-11-09)" were revised on that date. Status tags: BUILT / NOT BUILT.

## Purpose
Every transcription stenographr makes (from clips, notes or typing) is also copied to one known
location. That way I can see everything I dictated on a given day and copy text back out if
delivery fails. The archive is a backup: readable, copy-pasteable, no JSON in anything I read.
All transcripts and daily files are plain `.txt`, not `.md` (they are plain text, and `.md` opens in
Obsidian). (changed 2026-11-09)

## Layout (changed 2026-11-09)
```
/data/transcripts/                    archive root (configurable in ~/.config/stenographr/config.toml)
  steno-2026-11-09.txt                daily file, one per day, append only
  steno.log                           error and event log, plain text
  clips/
    clip-2026-11-08-063820.txt        archive copy of a phone (Samsung-named) video's transcript
    clip-2025-11-27-155055_001.txt    the Samsung suffix is kept
  other/
    2026-11-08-some-talk.txt          any other video: <recording date>-<stem>
```
- Files sit loose in the folder. The only subfolders are `clips/` and `other/`, and both are flat.
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

Dictation sessions (NOT BUILT): each session is a start/end block:
```
start: 2026-11-08 08:22:00 · notes · /data/phone/tests
This is an example of speech to text, test test test.
end: 2026-11-08 08:23:10 · 1m10s · ok

start: 2026-11-08 08:25:00 · type · Firefox — Claude
This is an example of speech to text, test test test.
end: 2026-11-08 08:26:10 · 1m10s · FAILED: text not typed, see steno.log
```
- The start line records when, which mode, and where the text went: the folder for notes, the
  app or window for typing.
- The end line records when it ended, how long it took, and whether delivery worked. A failure
  shows here first, with the details in `steno.log`.
- A session is everything from starting dictation to stopping it, not one block per phrase.
- **Open:** timestamps within a session. For long dictations, maybe a time-of-day prefix per phrase
  or paragraph. To settle by trying it.

## 3. Error log (BUILT for clips): `steno.log`
- Plain text, one line per event: time, level, session or file, message. A single log; there is no
  separate `steno.err`. (changed 2026-11-09)
- It records starts and finishes, the device chosen and why, and every error with enough detail
  to understand what happened. Purpose: if I dictate and nothing shows up, this file says why.

## 4. recall (NOT BUILT)
- `stenographr recall` (aliasable to `recall`) copies the text of the last session in the daily
  file to the clipboard. `recall 2` copies the one before that.
- It reads the daily file, so it works even if delivery failed.
- Dictation in type mode also puts its text on the clipboard (section 5); recall is the way to get
  back an earlier session. (changed 2026-11-09: no longer "only on demand")

## 5. Dictation modes (NOT BUILT)
- **Clip:** described in section 1 (built).
- **Notes mode** (changed 2026-11-09): `steno` in a terminal shows the text in the terminal and
  writes `./steno-YYYY-MM-DD.txt` in the current folder; the full session also goes to the daily file.
  **Open:** live vs written at stop; whether that file is added to `.gitignore`.
- **Type mode** (changed 2026-11-09): Ctrl+` toggles it. The text is typed at the cursor AND put on the
  clipboard; the full session (with which app or window) goes to the daily file. Typing uses `ydotool`
  (installed, verified working on this machine). `wl-copy` is installed for the clipboard.
- **Recording indicator** (changed 2026-11-09): GNOME's built-in mic icon in the top bar (verified: it
  appears with `pw-record`). No notifications.
- **Mic** (changed 2026-11-09): the WirePlumber config in `system/wireplumber` (PR #3) names the mic
  2i2 `scarlett-mic` (matched by USB product ID 8016) and makes it the default input. stenographr
  records from node `scarlett-mic`, channel 1 (AUX0). Never the laptop mic. If `scarlett-mic` is
  missing, record nothing and log it.
- **Still to verify before building:** reading the focused window's title or app may not be possible
  for native Wayland apps under GNOME; find out what is possible and log "unknown" otherwise.

## Other decisions
- Corrections file for mis-heard names: dropped (transcripts mostly go to AI, which infers meaning).
  (changed 2026-11-09)
- The CPU run used 4.9 GB of RAM, against about 800 MB for a comparable tool: later.
  (changed 2026-11-09)
