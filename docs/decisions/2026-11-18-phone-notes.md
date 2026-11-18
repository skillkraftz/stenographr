---
id: 2026-11-18-phone-notes
status: implemented
topic: phone
prs: []
---
# `stenographr phone`: dictate on the phone, the note lands on the laptop

- **Decision:** a small stdlib web server (`stenographr phone`, 127.0.0.1:3111) takes recordings from a one-screen page, saves the audio as sent into `audio/` (`-phone.webm` / `-phone.m4a`), and a single worker transcribes in upload order (CPU, `transcribe_long`, like the laptop's clean pass) and appends one `phone` session block to the daily file. Per-note state lives in `<archive>/phone/<id>.json`, so a restart resumes. The page sends the raw body with the note id in a header and retries until the server answers; the same id twice is harmless. The phone reaches it through `tailscale serve --https=443` (tailnet only, never Funnel; HTTPS is what makes the microphone available on phones). A systemd user service is available but opt-in (`--install` / `--remove`).
- **Why:** the notes stay on the user's own machine, in the same files as laptop dictation. The model is loaded per burst of notes and dropped when the queue is empty: the CPU load takes ~1.2 s (from steno.log), and keeping it resident costs ~5 GB of RAM while the laptop is in use; running on the CPU means it never fights the GPU. The original container is kept instead of re-encoding to Opus (no quality loss, no extra step that could fail; recall already reads any `audio/...` pointer). The whole block is written in one append because the daily file is shared with live sessions, whose lines must not land inside it; the reverse (a phone block inside an open live session) is handled by the parser (`daily.parse_sessions`), which reads it as its own session and goes on with the live one.
- **Rejected:** a resident model (RAM); multipart uploads (raw body is simpler and needs no parser); a framework like Flask/FastAPI (a dependency for four routes); auth (the tailnet is the boundary, the server only listens on localhost); Funnel (public internet).
