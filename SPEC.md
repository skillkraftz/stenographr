# stenographr: transcript backup and archive spec

Read this before changing behaviour; update it when behaviour changes. Lines marked
"(changed 2026-11-09)" were revised on that date. Status tags: BUILT / NOT BUILT.

## Purpose
The goal of the whole project: `/data/transcripts` must let me put everything back together: what was said,
when, where it went, and the audio it came from. The daily file `steno-YYYY-MM-DD.txt` is the single manifest.

Every transcription stenographr makes (from clips, notes or live sessions) is also copied to one known
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
    2026-11-10-200600-live.opus
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

Dictation sessions (BUILT 2026-11-09; timestamps and audio pointer 2026-11-10; `live` 2026-11-10), written by
`notes` and `live`:
```
start: 2026-11-10 20:05:00 · notes · /home/andy/projects/hyperbeam/steno/steno-2026-11-10.txt · audio/2026-11-10-200500-notes.opus
[20:05:02] <sentence>
end: 2026-11-10 20:12:30 · 7m30s · ok
start: 2026-11-10 20:06:00 · live · unknown · audio/2026-11-10-200600-live.opus
[20:06:01] <live phrase>
[20:06:05] <live phrase>
clean:
[20:06:01] <clean sentence or paragraph>
end: 2026-11-10 20:07:30 · 1m30s · ok · copied
```
- **`live` blocks (changed 2026-11-10):** the live phrases are appended as they are recognised (so a crash
  keeps everything said); `clean:` and the clean lines are appended when the session has been
  re-transcribed in one pass; the end line carries what was done with the clean text: `ok · copied`,
  `ok · appended to claude <session>`, `ok · sent to claude <session>`, `ok · new take`, `ok · closed`, `ok · not copied (window closed)` (the window
  went away), or `FAILED: ...`
  (`clipboard failed`, `send to claude failed`, `clean pass failed`). If the clean pass failed but a choice was
  made, the live text is what was delivered and the end line says so. A session killed hard has the start line,
  the live lines and the audio pointer and no end line.
- **Audio pointer (changed 2026-11-10):** the last part of the start line is the session's audio file, relative to
  the archive root. If the audio could not be kept it reads `audio: none` and the end line says
  `ok (audio FAILED, see steno.log)`; the session itself still runs and delivers. A session that never got
  going (e.g. mic not found) has no audio part. Older files (no audio part) are still read by recall.
- **Where (changed 2026-11-10):** for notes it is the notes file's full path (not just the folder); for live
  it is always `unknown`.
- **Audio time zero = text time zero:** the audio file starts at the first sample from the recorder, and the
  text timestamps are the recording start + each sentence's offset counted from that same sample, so
  `[HH:MM:SS] - start line time` is the position in the audio (to within the whole-second resolution of the
  stamps; verified against the real model).
- **Sentence lines carry a time of day (changed 2026-11-10):** `[HH:MM:SS]` = the recording start + the
  sentence's offset into the audio (when it started being said, not when it was transcribed). This is in
  the daily file and in the notes file, for both notes and live sessions. start/end lines and clip lines
  are unchanged. Timestamps are only in these kept records: never in the terminal output of `notes`, the
  live screen, the clipboard, the text sent to Claude, or recall's output.
- The start line records when, which mode (`notes` or `live`) and where the text went: the notes file for
  notes, `unknown` for live (it goes to the clipboard or a Claude pane). (Older files also have `type` sessions,
  where the window was always `unknown`: GNOME Wayland gives no window title without an extension.)
- **One write per line (changed 2026-11-11):** every line added to a daily/notes file (session lines and `clip`
  pointer lines) is one `write()` on an append-only file, so lines of different writers never mix inside a line.
  Whole lines from `clip` can still land inside an open session block; `recall` skips pointer lines there and
  the block keeps its text and its end line.
- **Audio is written by the recorder thread (changed 2026-11-11):** the thread that reads `pw-record` is the
  only writer of the Opus encoder, so everything recorded reaches the `.opus` even when the model fails to load
  or transcription breaks (the block still has its start line with the audio pointer, a
  `FAILED: engine failed|transcription error, see steno.log` end line, and the reason in steno.log).
- **Device (changed 2026-11-11):** `live` and `notes` use the CPU by default (the GPU gives ~70 ms per phrase and
  nothing for the clean pass, and holds ~670 MiB). `[device] device = "gpu"` in the config (or `--device gpu|auto`)
  overrides; `auto` in the config counts as the default (CPU) for them. The device is decided once per app/run and
  reused by every capture and clean pass. `clip` is unchanged: auto, decided before each file.
- **clip writes both transcripts or neither (changed 2026-11-11):** if the archive copy cannot be written, the
  sibling `.txt` is removed again, steno.log says why, the source counts as failed (`FAILED: see steno.log` line
  in the daily file, no pointer; exit 1) and the other sources carry on. The pointer line is written only after
  both files exist.
- The end line records when it ended, how long the recording was (`42s`, `7m30s`, `1h02m05s`) and the
  result: `ok`, `ok (no speech)`, or `FAILED: <short reason>, see steno.log` (mic not found,
  clipboard failed, recorder exited, transcription error). A failure shows here first, with the
  details in `steno.log`.
- A session is everything from starting dictation to stopping it, not one block per phrase. Both modes
  append each sentence as it is spoken, so a crash leaves a block with no end line; recall still sees it (its text is the lines after its start).
  A session that never got going (e.g. mic missing) leaves a start/end pair with no text.

## 3. Error log (BUILT for clips): `steno.log`
- Plain text, one line per event: time, level, session or file, message. A single log; there is no
  separate `steno.err`. (changed 2026-11-09) Neither are there per-capture `.err` files: what `pw-record` prints on
  stderr is read into steno.log (WARN, "pw-record said: ...") and ffmpeg's goes into the "audio not saved" error.
  Cascade rule: if something is not in the daily file, steno.log says why. (changed 2026-11-11)
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
- **`live` pieces (changed 2026-11-10):** the piece's text is its clean block when there is one, else its live
  lines (so a crashed or clean-less session still shows). Old files, with no `clean:` lines or audio pointers,
  parse as before.
- What is copied is text only, never timestamps: a session's sentences joined with spaces; for a clip/other
  piece, the spoken text of that transcript file (no header, no time prefixes). If the transcript file is
  missing, it says so and copies nothing. `recalled:` and the full text are printed after copying.
- `recall N` copies piece N of that file without listing.

## 5. Dictation modes (BUILT 2026-11-09; live screen 2026-11-10)
- **Clip:** section 1.
- **Live screen**, `stenographr live` (changed 2026-11-10; replaces the old type mode and its ydotool code, which
  typed each phrase into whatever window was focused, broke sentences at every pause, and leaked Ctrl into the typed
  keys). Textual. It never types into other windows. Banner "Live preview · final text is cleaned up when you stop".
  A capture records `scarlett-mic` exactly like notes (48 kHz, channel 1, audio to
  `<archive>/audio/YYYY-MM-DD-HHMMSS-live.opus`), shows each phrase as it is recognised and appends it,
  timestamped, to the daily file as it goes. Mode `live`, target `unknown`. Several instances can be open at once
  (changed 2026-11-10: one per tmux pane is expected); there are two kinds.
  - **Popup** (`stenographr live --popup`; opened by Ctrl+`): a kitty window, 80x25. Starts recording at once. Stop
    (`s` or the button) -> "Cleaning up…" -> the clean text with **Copy (y)**, **Claude append (a)**, **Claude send (e)**,
    **Close (q / Esc)**. Any choice writes the clean block and end line, then exits (the window closes).
  - **Loop** (`stenographr live` started any other way, in a terminal or tmux pane; driven only by clicking, the
    hotkey never touches it): opens on **Ready** (buttons **Start** (Enter or `r`) and **Close** (`q`); the
    microphone is not open, so GNOME's mic icon is off). Start -> recording -> Stop -> cleaning up -> the clean text
    with **Copy (y)** (wl-copy, back to Ready), **Claude append (a)** and **Claude send (e)** (back to Ready), **New (r)**
    (delivers nothing, back to Ready), **Close (q / Esc)** (delivers nothing, quits). The Ready screen shows the
    last action and its time ("Last: sent to claude alpha · 22:14"). Every capture is its own session block with
    its own audio file.
  - **The model is loaded once** per app, in the background at start, and kept for the app's lifetime (`Engines`,
    now locked so a capture and the preload never build it twice). A capture started before it has loaded still keeps
    all its audio (the recorder runs first and is queued). GPU memory is freed when the app quits. Measured
    2026-11-10: each open instance holds about 670 MiB of GPU memory (model + CUDA context + the arena after a
    clean pass); three instances were 2.0 GB above a 0.7 GB desktop baseline. The existing free-VRAM check (1000 +
    500 MiB) sends an instance that starts without room to the CPU.
  - **One recording at a time.** Every instance registers `<runtime state dir>/live/<pid>.json` = {pid, kind
    (popup|loop), where (the tmux session of its pane, `terminal`, or `popup`), recording}; entries whose process
    is gone are ignored and removed. Before any instance starts recording (a popup opening, or Start in a loop) it
    looks for another instance that is recording. If there is one it shows "Recording in <where>. Stop it and
    record here?" with **Stop it and record here** (`y`) and **Cancel** (`n` / Esc). Stop it sends SIGUSR1 to the
    other instance (it stops, shows its own clean text and buttons, and stays open: it is never closed or killed),
    waits until it has let go of the microphone, then records here. Cancel: a popup closes, a loop goes back to Ready.
  - **Ctrl+` (`stenographr live --toggle`) only ever looks at popups.** A popup is recording -> it is stopped
    (SIGUSR1). A popup exists in any other state (notice, cleaning, buttons) -> it is raised and focused (`wmctrl -x -a stenographr-live`). No popup (and none was
    launched in the last 10 s) -> kitty opens a window, 80x25, titled "stenographr live" (`-o initial_window_width=80c
    -o initial_window_height=25c -o remember_window_size=no -o linux_display_server=x11`: the popup only runs under XWayland), running
    `stenographr live --popup`, and a detached `wmctrl -x -r stenographr-live -b add,above` (retried for ~10 s until the window
    exists) keeps it on top. Loop instances, ready or recording, are never signalled. Needs `wmctrl`. The window is found by its class (`--class stenographr-live`, `wmctrl -x`), not its title: titles match by substring, so a browser tab named like the popup could be hit.
  - After "Cleaning up…": the session's 16 kHz audio is kept in memory while recording (the same samples the audio file
    got) and decoded once at the end by `engine.transcribe_long` (the **clean pass**): Silero VAD with 0.3 s pauses and a
    30 s cap, neighbouring segments merged into chunks of up to ~30 s and cut only at the longest pauses, each chunk
    decoded in one go. That keeps sentences whole (the live stream cuts at every 0.6 s pause and loses context: "is
    Only Acceptable to use. when the work will grow." becomes one sentence). About 0.03 x realtime on CPU or GPU; a 30 s
    chunk needs ~1.2 GB of VRAM at most, and the GPU->CPU fallback applies as everywhere. If delivery fails the text
    stays on screen and the end line says FAILED.
  - **Claude: append and send** (two buttons, replacing "Send to Claude"). The target is hyperbeam's Claude pane, found in
    this order (`tmuxsend.choose_target`, plain `tmux`, no hyperbeam code):
    1. `HB_CLAUDE_PANE` (a pane id like `%12`, set by hyperbeam in every project session) in our own environment;
    2. else, inside tmux (`$TMUX_PANE` set): the session our pane is in (`tmux display-message -p -t $TMUX_PANE '#{session_name}'`),
       then `tmux show-environment -t <session> HB_CLAUDE_PANE`.
    If an id comes out and that pane exists, Append/Send go there with no question, and that pane's session name is shown at
    the right end of the blue "Live preview" bar (a loop shows its own tmux session there until a target is known). If the id is
    set but the pane is gone, the status line says "hyperbeam's Claude pane not found" and the buttons open a short list of the
    sessions whose pane runs `claude` (`pane_current_command`). Not in hyperbeam (no variable anywhere, e.g. the kitty popup):
    that list, as before. With no target and no Claude pane anywhere both buttons are disabled. The old guess from the
    attached tmux client's session is gone. The labels are just "Claude append (a)" and "Claude send (e)".
    - **Append (a):** `tmux send-keys -t <pane> -l -- "<clean text, one line> "`: the text plus ONE trailing space, no Enter.
      Whatever is already in Claude's input stays, so several takes can be appended one after another.
    - **Send (e):** the same `send-keys -l` with the text (no trailing space), then `tmux send-keys -t <pane> Enter` (as hyperbeam's
      `send_line` does): everything now in Claude's input, earlier appends included, is submitted. This is the ONLY place stenographr
      ever presses Enter (rule relaxed 2026-11-10 for this button only).
    - Not `s` (it is Stop on the recording screen; a double tap must never submit), and Enter stays disabled at the button step.
  - **Copy (y)** also adds one trailing space, so a second take, or typing, continues cleanly.
  - **Layout adapts to the terminal** (changed 2026-11-10; it runs in tmux split panes, sometimes a tall narrow sidebar): the
    buttons form a grid with as many columns as fit (a label needs ~26 cells; one column in a narrow pane, one-line buttons
    below 40 columns), and the banner, status, "Last:" line and clean text wrap and reflow when the pane is resized. Every
    button keeps its whole label from 28 columns up (tested at 28x40, 36x30, 60x25, 80x25 and 120x20).
  - **Window closed any other way** (X button = SIGHUP, kill = SIGTERM): recording stops, the clean pass runs if it
    can, the end line says `ok · not copied (window closed)` (or `FAILED: clean pass failed`); nothing is
    delivered. A second hang-up during this wrap-up is ignored. SIGKILL leaves the live lines and audio, no end line.
    (Once, in PR #8's testing, a session logged `clean pass failed: RuntimeError: no running event loop` during such
    a shutdown; it was not reproducible in 2026-11-10's tests of back-to-back captures, stops from another
    instance, repeated signals and tmux panes, and the log now records where a clean-pass failure happened.)
  - Verified 2026-11-10: kitty `-o linux_display_server=x11 -o remember_window_size=no -o initial_window_width=80c
    -o initial_window_height=25c` gives exactly 25 rows x 80 columns; when that window closed, X focus went back to
    the previously active window. Always on top: GNOME/Wayland has no API, so the popup (only) runs under XWayland and `wmctrl` (installed 2026-11-11) sets
    `_NET_WM_STATE_ABOVE` and raises it. Not verified in a real window from the assistant's shell (a guard blocks GUI apps there).
  - **Copy falls back to xclip (changed 2026-11-11):** on GNOME wl-copy needs keyboard focus on a Wayland window; the popup holds
    the focus as an X11 window (XWayland), so wl-copy hung for the whole 10 s (steno.log 2026-11-11 12:28: `clipboard (wl-copy) failed:
    TimeoutExpired`). `clipboard.copy` now gives wl-copy 3 s, then sends the text through `xclip -selection clipboard` (detached the
    same way; needs `xclip`). Still unverified in a real popup: see the hand test in the PR.
  - **Copy (wl-copy)** is `clipboard.copy`, shared by live and recall: stdin is the only pipe, stdout/stderr go to /dev/null, and wl-copy
    starts in its own session. wl-copy leaves a background process that serves the clipboard; with captured or inherited pipes the
    caller waits for it, and in the popup's process group it dies when the window closes (clipboard empties).
- **Streaming preview in `live` (BUILT 2026-11-11):** while recording, words appear as they are spoken: lowercase, no
  punctuation, the line in progress redrawn on screen as it grows, a new line at each endpoint. The streaming model is
  `sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25` (`engines/nemotron.py`, sherpa-onnx online
  transducer, CPU, 2 threads, ~1.3 GB RSS, loads in ~1.6 s; license: NVIDIA Open Model License). It replaces the per-phrase
  Parakeet live decode: while recording only the streaming model runs. Lines are cut by `nemotron.py` from the token times and the model is never reset (its own endpointing resets the model
  and a reset drops the audio still in its pipeline: 6-7 % of the words lost, measured): a line ends when 1.8 s of audio
  pass without a new word (about a 1.2 s pause; the model lags a word by ~0.6 s) or at the next word after 15 s. On saved
  audio that gave 14 lines for 89 words and 39 lines for 460 words, with no words lost against an unsegmented run. Measured 2026-11-11 on
  saved audio: a word shows about 0.4 s after it is spoken (median; 0.7 s from the word's start). Each finished line goes
  to the daily file at once as `[HH:MM:SS] text` (lowercase; the time is the line's first word); the line in progress is
  screen-only. Both models load in the background at app start (the streaming model first); audio is queued until the
  streaming model is ready, as before. If the streaming model cannot load (missing files...), steno.log says so and that
  capture uses the per-phrase Parakeet decode. At stop nothing changes: the clean pass (Parakeet, `transcribe_long`) runs,
  its text replaces the live text on screen, the `clean:` block is written, and the button step is as before. Needs the model
  in the models folder next to Parakeet (README). `notes` is not touched: it keeps the per-phrase Parakeet decode and never
  loads the streaming model. No config switch.
- **Notes mode**, `stenographr notes` (aliasable to `steno`): runs in the terminal until Ctrl+C. Text
  appears sentence by sentence as I pause (Silero VAD fed live, 0.6 s of silence ends a sentence); each
  sentence is appended at once to the notes file and to the daily file (timestamped there; the terminal
  shows bare sentences). Notes and live share one streaming loop (`dictate._live`).
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
  (`[dictation] mic`), 48 kHz float32, 2 channels (AUX0/AUX1), and keeps channel 1 (`[dictation] channel`,
  AUX0: the voice; AUX1 is silent). The node is checked before recording; if it is missing nothing is
  recorded, the daily file gets `FAILED: mic scarlett-mic not found` and it is logged. Never another input.
- **Hotkey:** `stenographr keybinding install` adds (or updates) a GNOME custom keybinding "stenographr dictation",
  `<Control>grave`, command = the absolute path of `stenographr` + ` live --toggle` (it only opens or stops the popup); it appends to the existing
  list and never changes other entries. `stenographr keybinding remove` removes only that entry.
- Needs `pw-record`, `pw-dump`, `ffmpeg` (with libopus), `wl-copy` (and `xclip` as its fallback in the popup), `kitty` (for the Ctrl+` window), `tmux` (only for Send to
  Claude), `git` (notes mode only); the one Python dependency added for this is `textual`.

## 6. `stenographr update` (BUILT 2026-11-11)
- The tool is installed editable, so the running code is the checkout the package sits in: the source path is two folders
  above `update.py`, whatever the current directory is. Not a git checkout -> message, exit 1.
- Prints `source`, `branch`, `commit` (short hash + subject) and `origin: N ahead, M behind origin/main` after `git fetch`
  (a failed fetch stops with exit 1).
- Not on `main`, or uncommitted changes (the files are listed): says so and stops, exit 1. It never stashes, resets or
  switches branches.
- Otherwise `git pull --ff-only` when behind, prints the pulled commits, and if `pyproject.toml` changed in them reruns
  `uv tool install --editable ".[gpu]" --force` from the checkout. Ends with `updated to <commit>` or `up to date at <hash>`.
- Then lists the running live instances from the registry (pid, kind popup/loop, where: popup, tmux pane or terminal);
  after a pull it says to restart them. It never stops or kills anything.

## Other decisions
Design decisions are one file each in `docs/decisions/` (index: `docs/DECISIONS.md`).
