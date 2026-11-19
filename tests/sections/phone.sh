#!/usr/bin/env bash
# Section: phone (the web server for dictating on a phone). Run alone: tests/run-tests.sh phone
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
echo "== phone"
# The real ffmpeg makes the fixtures and decodes them (the fake one ignores its input): a private bin dir before the fakes.
REALFF=$(PATH=${PATH#"$FB":} command -v ffmpeg); REALFP=$(PATH=${PATH#"$FB":} command -v ffprobe)
mkdir -p "$W/fx" "$W/realbin"
if [[ -n $REALFF ]]; then
  ln -s "$REALFF" "$W/realbin/ffmpeg"; [[ -n $REALFP ]] && ln -s "$REALFP" "$W/realbin/ffprobe"
  export PATH=$W/realbin:$PATH
  ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2" -c:a libopus "$W/fx/android.webm"
  ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2" -c:a aac "$W/fx/iphone.mp4"
else
  echo "  (no real ffmpeg here: the fixtures are placeholder bytes and the fake ffmpeg 'decodes' them)"
  head -c 3000 /dev/urandom > "$W/fx/android.webm"; head -c 3000 /dev/urandom > "$W/fx/iphone.mp4"; export FAKE_FF_SECONDS=2
fi
head -c 2500000 /dev/zero > "$W/fx/big.webm"
DAY=$(date +%F); DAILY=$A/steno-$DAY.txt
export FAKE_ENGINE_CLEAN_TEXT="Phone note text."
BIGCONF=$'[phone]\nmax_mb = 1'

SPID=
start() {      # start [extra config]: the server on a free port; sets $URL
  mkconf "$1"; : > "$W/srv.out"
  steno phone --port 0 > "$W/srv.out" 2> "$W/srv.err" & SPID=$!
  for _ in $(seq 100); do grep -q "listening on" "$W/srv.out" && break; sleep 0.1; done
  PORT=$(grep -o ':[0-9]*  ' "$W/srv.out" | tr -d ': '); URL=http://127.0.0.1:$PORT
}
stop() { [[ -n $SPID ]] && kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; SPID=; }
post() {       # post FILE ID CONTENT-TYPE [TITLE] [SECONDS]: prints the HTTP status
  curl -s -o "$W/post.out" -w '%{http_code}' -X POST --data-binary "@$1" -H "Content-Type: $3" -H "X-Note-Id: $2" \
       -H "X-Title: $(printf %s "${4:-}" | "$PY" -c 'import sys,urllib.parse as u; print(u.quote(sys.stdin.read()))')" -H "X-Duration: ${5:-2}" "$URL/api/notes"
}
field() {      # field ID NAME: one field of today's note list
  curl -s "$URL/api/notes" | "$PY" -c 'import sys,json; print(next((n[sys.argv[2]] for n in json.load(sys.stdin) if n["id"]==sys.argv[1]), ""))' "$1" "$2"
}
waitfor() {    # waitfor ID STATUS: until the note has that status (max 20 s)
  for _ in $(seq 200); do [[ $(field "$1" status) == "$2" ]] && return 0; sleep 0.1; done; return 1
}

# ---- upload: audio saved, text appended in the session format
fresh; start ""
check "listens on 127.0.0.1 only" 'ss -ltn | grep -q "127.0.0.1:$PORT " && ! ss -ltn | grep -qE "(0.0.0.0|\*|\[::\]):$PORT "'
check "GET / serves the page, manifest and icon" '[[ $(curl -s $URL/ | grep -c "MediaRecorder") -ge 1 && $(curl -s $URL/manifest.webmanifest | grep -c standalone) == 1 && $(curl -s $URL/icon-192.png | head -c 4 | tail -c 3) == PNG ]]'
check "the page has a Copy button per note and selectable text" 'curl -s $URL/ | grep -q "class=\"copy" && curl -s $URL/ | grep -q "user-select:text"'
check "Android webm: 200, audio kept as sent in audio/*-phone.webm" '[[ $(post "$W/fx/android.webm" aaaaaaaa-0001 audio/webm "Shopping list") == 200 ]] && [[ $(ls "$A/audio" | grep -cE "^[0-9-]{17}-phone\.webm$") == 1 ]] && cmp -s "$W/fx/android.webm" "$A"/audio/*-phone.webm'
check "Android webm: transcribed, state done, text in the list" 'waitfor aaaaaaaa-0001 done && [[ $(field aaaaaaaa-0001 text) == "Phone note text." ]]'
check "daily file: one phone block, in the format of the other sessions" '[[ $(grep -c "^start:" "$DAILY") == 1 ]] && grep -qE "^start: $DAY [0-9:]{8} · phone · Shopping list · audio/[0-9-]{17}-phone\.webm$" "$DAILY" && grep -qE "^\[[0-9:]{8}\] Phone note text\.$" "$DAILY" && tail -1 "$DAILY" | grep -qE "^end: $DAY [0-9:]{8} · 2s · ok$"'
check "recall's parser reads the block (mode phone, audio, text)" '"$PY" -c "
import sys; from stenographr import daily
p = daily.parse_sessions(open(sys.argv[1]).read())
assert len(p)==1 and p[0].mode==\"phone\" and p[0].where==\"Shopping list\" and p[0].audio.endswith(\"-phone.webm\") and p[0].text==\"Phone note text.\" and p[0].status==\"ok\", p
" "$DAILY"'
check "iPhone mp4 (aac): 200, kept as audio/*-phone.m4a, transcribed" '[[ $(post "$W/fx/iphone.mp4" bbbbbbbb-0002 audio/mp4) == 200 ]] && waitfor bbbbbbbb-0002 done && ls "$A/audio" | grep -qE "^[0-9-]{17}-phone(-2)?\.m4a$" && [[ $(grep -c "^start:" "$DAILY") == 2 ]] && grep -q " · phone · unknown · audio/" "$DAILY"'
check "the same note id again (a retry): answered, nothing saved twice" '[[ $(post "$W/fx/iphone.mp4" bbbbbbbb-0002 audio/mp4) == 200 ]] && [[ $(ls "$A/audio" | wc -l) == 2 && $(grep -c "^start:" "$DAILY") == 2 ]]'
check "steno.log has the upload and the finish" 'grep -q "INFO  aaaaaaaa-0001 upload saved: audio/" "$LOG" && grep -q "INFO  aaaaaaaa-0001 finish: 1 lines, ok" "$LOG"'
check "no upload leftovers in phone/" '[[ -z $(ls -A "$A/phone" | grep -vE "\.json$|^[0-9]{4}-") ]]'

# ---- refusals
check "an upload over the limit is refused with 413 and nothing is saved" 'stop; fresh; start "$BIGCONF"; [[ $(post "$W/fx/big.webm" cccccccc-0003 audio/webm) == 413 ]] && [[ ! -d $A/audio || -z $(ls -A "$A/audio") ]] && [[ ! -e $DAILY ]]'
check "other paths and methods are refused (404/405), a bad note id is 400" '[[ $(curl -s -o /dev/null -w %{http_code} $URL/etc/passwd) == 404 && $(curl -s -o /dev/null -w %{http_code} -X POST -d x $URL/other) == 404 && $(curl -s -o /dev/null -w %{http_code} -X DELETE $URL/api/notes) == 405 && $(curl -s -o /dev/null -w %{http_code} -X POST -d x -H "X-Note-Id: ../x" $URL/api/notes) == 400 ]]'

# ---- queue order: three notes in a row come out in the order they were uploaded
stop; fresh; printf 'first note\nsecond note\nthird note\n' > "$W/seq"; export FAKE_ENGINE_CLEAN_SEQ=$W/seq FAKE_ENGINE_CLEAN_DELAY=0.4 FAKE_ENGINE_COUNT=$W/engines
start ""
for i in 1 2 3; do post "$W/fx/android.webm" "dddddddd-000$i" audio/webm "n$i" >/dev/null; done
check "queue: the list shows them waiting or working before the first is done" '[[ $(curl -s $URL/api/notes | grep -cE "queued|working") -ge 1 ]]'
check "queue: all three done, texts in upload order in the daily file" 'waitfor dddddddd-0003 done && [[ $(grep -E "^\[" "$DAILY" | sed "s/^\[[0-9:]*\] //" | tr "\n" "|") == "first note|second note|third note|" ]] && [[ $(grep "^start:" "$DAILY" | grep -o "· n[123] ·" | tr -d "\n") == "· n1 ·· n2 ·· n3 ·" ]]'
check "queue: the model is loaded once for the burst, not once per note" '[[ $(wc -l < "$W/engines") -le 2 ]]'
unset FAKE_ENGINE_CLEAN_SEQ FAKE_ENGINE_CLEAN_DELAY FAKE_ENGINE_COUNT

# ---- a failed transcription keeps the audio and marks the note
stop; fresh; FAKE_ENGINE_FAIL=1 start ""
post "$W/fx/android.webm" eeeeeeee-0004 audio/webm "Will fail" >/dev/null
check "failed transcription: note marked failed, audio kept, FAILED block in the daily file, reason in steno.log" 'waitfor eeeeeeee-0004 failed && ls "$A"/audio/*-phone.webm >/dev/null && tail -1 "$DAILY" | grep -qE "· FAILED: transcription failed, see steno.log$" && grep -q "ERROR eeeeeeee-0004 RuntimeError: fake model load failure" "$LOG"'
check "failed note: the server keeps serving" '[[ $(curl -s -o /dev/null -w %{http_code} $URL/api/notes) == 200 ]]'

# ---- a restart picks up what was still queued
stop; fresh; mkdir -p "$A/audio" "$A/phone"; cp "$W/fx/android.webm" "$A/audio/$DAY-101010-phone.webm"
printf '{"id": "ffffffff-0005", "start": "%sT10:10:10", "title": "Left over", "seconds": 2.0, "audio": "audio/%s-101010-phone.webm", "status": "working", "text": "", "error": ""}' "$DAY" "$DAY" > "$A/phone/ffffffff-0005.json"
start ""
check "restart: a note left queued/working is transcribed" 'waitfor ffffffff-0005 done && grep -q "^start: $DAY 10:10:10 · phone · Left over · audio/$DAY-101010-phone.webm$" "$DAILY"'
stop

# ---- a restart after the block was appended but before the state was saved: written once
fresh; mkdir -p "$A/audio" "$A/phone"; cp "$W/fx/android.webm" "$A/audio/$DAY-111111-phone.webm"
printf '{"id": "ffffffff-0006", "start": "%sT11:11:11", "title": "Twice", "seconds": 2.0, "audio": "audio/%s-111111-phone.webm", "status": "working", "text": "", "error": ""}' "$DAY" "$DAY" > "$A/phone/ffffffff-0006.json"
printf 'start: %s 11:11:11 · phone · Twice · audio/%s-111111-phone.webm\n[11:11:11] Already there.\nend: %s 11:11:13 · 2s · ok\n' "$DAY" "$DAY" "$DAY" > "$DAILY"
start ""
check "restart: a note whose block is already in the daily file is marked done, not written again" 'waitfor ffffffff-0006 done && [[ $(grep -c "^start:" "$DAILY") == 1 && $(field ffffffff-0006 text) == "Already there." ]]'
stop

# ---- the real-world upload: content types with parameters, an unknown one, a connection that breaks half way
fresh; start ""
check "content type with codecs parameter (iPhone, Android) and an unknown one: audio kept, transcribed" '[[ $(post "$W/fx/iphone.mp4" gggggggg-0007 "audio/mp4;codecs=mp4a.40.2") == 200 && $(post "$W/fx/android.webm" gggggggg-0008 "audio/webm;codecs=opus") == 200 && $(post "$W/fx/android.webm" gggggggg-0009 application/octet-stream) == 200 ]] && waitfor gggggggg-0009 done && ls "$A/audio" | grep -qE "\.m4a$" && ls "$A/audio" | grep -qE "\.webm$" && ls "$A/audio" | grep -qE "\.audio$" && [[ $(grep -c "^start:" "$DAILY") == 3 ]]'
cat > "$W/cut.py" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"POST /api/notes HTTP/1.1\r\nHost: x\r\nX-Note-Id: hhhhhhhh-0010\r\nContent-Type: audio/webm\r\nContent-Length: 5000\r\n\r\n" + b"x" * 700)
s.close()
PY
"$PY" "$W/cut.py" "$PORT"; sleep 0.5
check "a connection cut half way: nothing saved, no leftover, no traceback, the server keeps serving, a retry works" '[[ -z $(ls -A "$A/phone" | grep -vE "\.json$|^[0-9]{4}-") && ! -e $A/phone/hhhhhhhh-0010.json && $(ls "$A/audio" | wc -l) == 3 ]] && ! grep -q Traceback "$W/srv.err" && [[ $(post "$W/fx/android.webm" hhhhhhhh-0010 audio/webm) == 200 ]] && waitfor hhhhhhhh-0010 done'
stop

# ---- the daily file has two writers: a phone block landing inside a laptop session (live) loses nothing
check "phone blocks in the middle of a live session: every line whole, the live session read to its end" '"$PY" - "$W" <<"PY"
import sys, datetime as dt, threading
from pathlib import Path
from stenographr import daily
from stenographr.log import Log
w = Path(sys.argv[1]); f = w / "two-writers.txt"; f.unlink(missing_ok=True)
now = dt.datetime(2026, 1, 1, 10, 0, 0)
sess = daily.Session(Log(w / "x.log"), "live", [(f, None)], now, "live", "unknown", "audio/a-live.opus")
def phone(i):
    for k in range(40):
        daily.append_line(f, daily.block_text(now, "phone", f"p{i}", f"audio/p{i}-{k}.webm", [(now, f"phone {i} {k} " + "word " * 300)], 2, "ok"))
ts = [threading.Thread(target=phone, args=(i,)) for i in range(3)]
[t.start() for t in ts]
for k in range(300): sess.line(f"live {k}", now)
[t.join() for t in ts]
sess.end(now + dt.timedelta(seconds=9), "copied")
ps = daily.parse_sessions(f.read_text())
live = [p for p in ps if p.mode == "live"]; ph = [p for p in ps if p.mode == "phone"]
assert len(live) == 1 and live[0].status == "copied", [(p.mode, p.status) for p in ps][:5]
assert live[0].text.split() == [x for k in range(300) for x in ("live", str(k))], "live lines lost"
assert len(ph) == 120 and all(p.status == "ok" and p.text.count("word") == 300 for p in ph), len(ph)
PY'

# ---- every note as its own text file: <archive>/phone/<day>/HH-MM-SS[-title-slug].txt
stop; fresh; start ""
post "$W/fx/android.webm" iiiiiiii-0011 audio/webm "Shopping list!" 7 >/dev/null; post "$W/fx/iphone.mp4" iiiiiiii-0012 audio/mp4 "" >/dev/null
waitfor iiiiiiii-0011 done; waitfor iiiiiiii-0012 done
PD=$A/phone/$DAY
check "text file with a title: HH-MM-SS-title-slug.txt; first line date time · title · duration · audio path, blank line, the text" 'F=$(ls "$PD"/*-shopping-list.txt) && [[ $(basename "$F") =~ ^[0-9]{2}-[0-9]{2}-[0-9]{2}-shopping-list\.txt$ ]] && [[ $(sed -n 1p "$F") =~ ^$DAY\ [0-9:]{8}\ ·\ Shopping\ list!\ ·\ 2s\ ·\ $A/audio/[0-9-]{17}-phone\.webm$ ]] && [[ -z $(sed -n 2p "$F") && $(sed -n 3p "$F") == "Phone note text." ]]'
check "text file without a title: HH-MM-SS.txt, no title field" 'F=$(ls "$PD" | grep -E "^[0-9]{2}-[0-9]{2}-[0-9]{2}\.txt$") && [[ $(sed -n 1p "$PD/$F") =~ ^$DAY\ [0-9:]{8}\ ·\ 2s\ ·\ $A/audio/[0-9-]{17}-phone\.m4a$ ]] && [[ $(sed -n 3p "$PD/$F") == "Phone note text." ]]'
check "atomic: no temp file left; the daily file has its two blocks as before" '[[ -z $(ls -A "$PD" | grep -v "\.txt$") && $(ls "$PD" | wc -l) == 2 && $(grep -c "^start:" "$DAILY") == 2 ]]'
check "atomic: an existing name is never overwritten, no temp left (write_note_file)" '"$PY" - "$A" <<"PY"
import sys
from pathlib import Path
from stenographr.phone import write_note_file, note_file
a = Path(sys.argv[1]); n = {"start": "2026-02-03T04:05:06", "title": "", "seconds": 3, "audio": "audio/x.webm", "text": "one"}
assert write_note_file(a, n) is True
n["text"] = "two"
assert write_note_file(a, n) is False
f = note_file(a, n)
assert f.read_text().endswith("\n\none\n"), f.read_text()
assert [p.name for p in f.parent.iterdir()] == ["04-05-06.txt"]
PY'
stop; fresh; FAKE_ENGINE_FAIL=1 start ""
post "$W/fx/android.webm" jjjjjjjj-0013 audio/webm "Nope" >/dev/null
check "failed transcription writes no text file (the failed mark stays)" 'waitfor jjjjjjjj-0013 failed && [[ ! -e $A/phone/$DAY || -z $(ls -A "$A/phone/$DAY") ]]'
stop; fresh; start ""
for i in 14 15 16; do post "$W/fx/android.webm" "kkkkkkkk-00$i" audio/webm "t$i" >/dev/null; done
waitfor kkkkkkkk-0016 done; stop
F14=$(ls "$PD"/*-t14.txt); F15=$(ls "$PD"/*-t15.txt); F16=$(ls "$PD"/*-t16.txt)
rm "$F15"; rm "$F16"; echo "edited by hand" > "$F14"
printf '{"id": "oooooooo-0001", "start": "2026-03-01T09:08:07", "title": "Old one", "seconds": 4.0, "audio": "audio/2026-03-01-090807-phone.webm", "status": "done", "text": "Earlier text.", "error": ""}' > "$A/phone/oooooooo-0001.json"
steno phone --backfill > "$W/bf.out" 2>&1
check "backfill: the missing files (today and an earlier day) are made, the existing one is untouched, the count is printed" '[[ -f $F15 && -f $F16 && $(cat "$F14") == "edited by hand" && -f $A/phone/2026-03-01/09-08-07-old-one.txt && $(sed -n 3p "$A/phone/2026-03-01/09-08-07-old-one.txt") == "Earlier text." ]] && grep -q "3 text file" "$W/bf.out"'
steno phone --backfill > "$W/bf.out" 2>&1
check "backfill: a second run writes nothing" 'grep -q "0 text file" "$W/bf.out"'
rm "$F15"; start ""
check "server start also backfills" '[[ -f $F15 ]]'
stop

# ---- Host / Origin check, worker niceness
stop; fresh; start ""
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "Host: 127.0.0.1, localhost and a *.ts.net name are served" '[[ $(code $URL/api/notes) == 200 && $(code -H "Host: localhost:$PORT" $URL/api/notes) == 200 && $(code -H "Host: xps-1.tail9babd7.ts.net" $URL/api/notes) == 200 && $(code -H "Host: [::1]:$PORT" $URL/api/notes) == 200 ]]'
check "Host: a rebinding name (evil.example, a lookalike of ts.net, an empty Host) is 403 on GET and POST" '[[ $(code -H "Host: evil.example:$PORT" $URL/) == 403 && $(code -H "Host: evil.ts.net.evil.example" $URL/api/notes) == 403 && $(code -H "Host: 192.168.1.5:$PORT" $URL/api/notes) == 403 && $(code -H "Host:" $URL/api/notes) == 403 && $(code -X POST -d x -H "Host: evil.example" -H "X-Note-Id: llllllll-0001" $URL/api/notes) == 403 ]] && [[ ! -e $A/phone/llllllll-0001.json ]]'
check "Origin: same as Host passes, a cross-origin POST is 403 and saves nothing" '[[ $(code -X POST --data-binary "@$W/fx/android.webm" -H "Content-Type: audio/webm" -H "X-Note-Id: llllllll-0002" -H "Origin: https://evil.example" $URL/api/notes) == 403 && ! -e $A/phone/llllllll-0002.json && $(code -H "Origin: $URL" $URL/api/notes) == 200 && $(code -X POST --data-binary "@$W/fx/android.webm" -H "Content-Type: audio/webm" -H "X-Note-Id: llllllll-0003" -H "Origin: https://xps-1.tail9babd7.ts.net" -H "Host: xps-1.tail9babd7.ts.net" $URL/api/notes) == 200 ]]'
check "the transcription worker thread runs at nice 10, the other threads (web handlers, main) at 0" '"$PY" - "$SPID" <<"PY"
import glob, os, subprocess, sys
pids = [sys.argv[1]] + subprocess.run(["pgrep", "-P", sys.argv[1]], capture_output=True, text=True).stdout.split()
pid = next(p for p in pids if len(os.listdir(f"/proc/{p}/task")) > 1)      # the python server (threads), not a launcher shim
n = {f: int(open(f).read().rsplit(")", 1)[1].split()[16]) for f in glob.glob(f"/proc/{pid}/task/*/stat")}
assert list(n.values()).count(10) == 1 and n[f"/proc/{pid}/task/{pid}/stat"] == 0 and set(n.values()) == {0, 10}, n
PY'
stop

# ---- phone --install / --remove / --tailscale
export XDG_CONFIG_HOME=$W/xdg FAKE_SYSTEMCTL_LOG=$W/sysctl.log FAKE_TS_LOG=$W/ts.log; : > "$W/sysctl.log"; : > "$W/ts.log"
steno phone --install > "$W/inst.out" 2>&1; echo $? > "$W/rc"
U=$XDG_CONFIG_HOME/systemd/user/stenographr-phone.service
check "--install: unit written (runs 'stenographr ... phone'), enabled and started" '[[ $(cat "$W/rc") == 0 ]] && grep -qE "^ExecStart=.*stenographr phone$" "$U" && grep -q "enable --now stenographr-phone.service" "$W/sysctl.log"'
check "--install: restarts only after 10 s (a /data that is not mounted yet must not exhaust the start limit)" 'grep -qx "RestartSec=10" "$U"'
steno phone --remove > "$W/rem.out" 2>&1
check "--remove: service disabled, unit file gone; remove again says not installed" '[[ ! -e $U ]] && grep -q "disable --now stenographr-phone.service" "$W/sysctl.log" && steno phone --remove | grep -q "not installed"'
steno phone --tailscale > "$W/ts.out" 2>&1; echo $? > "$W/rc"
check "--tailscale: serve --bg --https=443 http://127.0.0.1:3111 (no funnel), prints the phone URL" '[[ $(cat "$W/rc") == 0 ]] && grep -qx "serve --bg --https=443 http://127.0.0.1:3111" "$W/ts.log" && ! grep -qi funnel "$W/ts.log" && grep -q "https://fake-host.tail0000.ts.net/" "$W/ts.out"'
steno phone --tailscale off > "$W/ts.out" 2>&1
check "--tailscale off: serve --https=443 off" 'grep -qx "serve --https=443 off" "$W/ts.log"'
FAKE_TS_DENY=1 steno phone --tailscale > "$W/ts.out" 2>&1; echo $? > "$W/rc"
check "--tailscale without operator rights: exit 1 and prints the sudo command" '[[ $(cat "$W/rc") == 1 ]] && grep -qF "sudo tailscale set --operator=\$USER" "$W/ts.out"'

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
