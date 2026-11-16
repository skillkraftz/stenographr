#!/usr/bin/env bash
# Section: notes. Run alone: tests/run-tests.sh notes
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== notes mode"
dfresh; ND=$W/nt; rm -rf "$ND"; mkdir -p "$W/gate"
nstart "$ND" FAKE_PW_GATE="$W/gate" FAKE_ENGINE_TEXT="one|two|three"
nwait 1; NF=$ND/steno-$(date +%F).txt
check "sentence 1: printed bare, already in both files (timestamped)" '[[ $(cat "$W/notes.out") == one ]] && grep -qE "^$TS one$" "$NF" && grep -qE "^$TS one$" "$DAILY" && ! grep -q "^end:" "$NF"'
check "notes file starts with the header, once" '[[ $(head -1 "$NF") == "stenographr notes · $ND" ]] && sed -n 2p "$NF" | grep -qE "^start: $BLK · notes · $NF · audio/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-notes\\.opus$" && [[ $(grep -c "^stenographr notes ·" "$NF") == 1 ]]'
check "daily file has no header line" '! grep -q "^stenographr notes" "$DAILY" && head -1 "$DAILY" | grep -q "^start: "'
touch "$W/gate/go2"; nwait 2; check "sentence 2 appears when it is spoken, not at the end" '[[ $(tail -1 "$NF") == *"] two" && $(tail -1 "$DAILY") == *"] two" ]]'
touch "$W/gate/go3"; nwait 3
nstop
check "Ctrl+C: exit 0; terminal shows 3 bare lines, no timestamps" '[[ $(cat "$W/rc") == 0 && $(cat "$W/notes.out") == "$(printf "one\ntwo\nthree")" ]]'
T0=$(sed -n 2p "$NF" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2} ·" | cut -d" " -f1)
check "notes file: [HH:MM:SS] = recording start + offset (0, 5, 10 s)" 'sed -n 3p "$NF" | grep -qx "\[$T0\] one" && sed -n 4p "$NF" | grep -qx "\[$(plus $T0 5)\] two" && sed -n 5p "$NF" | grep -qx "\[$(plus $T0 10)\] three"'
check "daily file: same timestamps" 'sed -n 2p "$DAILY" | grep -qx "\[$T0\] one" && sed -n 4p "$DAILY" | grep -qx "\[$(plus $T0 10)\] three"'
check "end line written to both files" 'tail -1 "$NF" | grep -qE "^end: $BLK · [0-9]+s · ok$" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok$"'
check "both files: start, 3 sentences, end" '[[ $(wc -l < "$DAILY") == 5 && $(wc -l < "$NF") == 6 ]]'
rm -rf "$W/gate"
nstart "$ND" FAKE_PW_CHUNKS=1 FAKE_ENGINE_TEXT="again"; nwait 1; nstop
check "second session, same day and folder: header still only once, 2 blocks" '[[ $(grep -c "^stenographr notes ·" "$NF") == 1 && $(grep -c "^start:" "$NF") == 2 && $(grep -c "^end:" "$NF") == 2 ]]'
check "notes outside a git repo: only the steno file is created" '[[ $(ls -A "$ND") == "steno-$(date +%F).txt" ]]'
check "steno.log: start, device, finish" 'grep -q " notes start: " "$LOG" && grep -q " notes device: " "$LOG" && grep -q " notes finish: 1 sentences, ok" "$LOG"'
dfresh; mkdir -p "$W/empty"; (cd "$W/empty" && FAKE_MIC_MISSING=1 steno notes 2>/dev/null); echo $? > "$W/rc"
check "notes, mic missing: exit 1, FAILED block in the daily file only" '[[ $(cat "$W/rc") == 1 && ! -e $W/pw.log ]] && grep -q "FAILED: mic scarlett-mic not found" "$DAILY" && ! ls "$W/empty"/steno-*.txt >/dev/null 2>&1'
dfresh; mkdir -p "$W/gate"; nstart "$ND" FAKE_ENGINE_LOAD_DELAY=1.2 FAKE_ENGINE_TEXT="one|two|three"; nwait 3 120; nstop
check "notes: audio that arrived while the model loaded is not lost" '[[ $(cat "$W/notes.out") == "$(printf "one\ntwo\nthree")" ]]'

echo "== notes in a git repo: <repo root>/steno/"
dfresh; RD=$W/repo; rm -rf "$RD"; mkdir -p "$RD/sub/deeper"; git init -q "$RD"
printf 'node_modules' > "$RD/.gitignore"                     # no trailing newline: must not glue onto it
nstart "$RD/sub/deeper" FAKE_PW_CHUNKS=1; nwait 1; nstop
RN=$RD/steno/steno-$(date +%F).txt
check "run from a subfolder: the notes file is <repo root>/steno/steno-DATE.txt, nothing loose in the folder" '[[ -f $RN && -z $(ls -A "$RD/sub/deeper") && ! -e $RD/steno-$(date +%F).txt ]]'
check "header names the repo root; the daily start line points at the notes file" '[[ $(head -1 "$RN") == "stenographr notes · $RD" ]] && grep -qE "^start: $BLK · notes · $RN · audio/" "$DAILY"'
check "steno/ appended to the repo root .gitignore (own line)" '[[ $(cat "$RD/.gitignore") == "$(printf "node_modules\nsteno/")" ]] && [[ ! -e $RD/sub/deeper/.gitignore ]]'
check "git ignores steno/ now; nothing staged or committed" '(cd "$RD" && git check-ignore -q steno/x && [[ -z $(git status --porcelain --untracked-files=all | grep steno) ]] && ! git rev-parse HEAD >/dev/null 2>&1)'
check "the addition is logged" 'grep -q "INFO  notes added steno/ to .*/repo/.gitignore" "$LOG"'
nstart "$RD/sub" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "second run: .gitignore not touched again, same notes file gets the second block" '[[ $(grep -c "^steno/" "$RD/.gitignore") == 1 && $(grep -c "^start:" "$RN") == 2 && $(grep -c "^stenographr notes ·" "$RN") == 1 ]]'
dfresh; RD2=$W/repo2; rm -rf "$RD2"; mkdir -p "$RD2"; git init -q "$RD2"; printf 'steno/\n' > "$RD2/.gitignore"
nstart "$RD2" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "already ignored: .gitignore left as is" '[[ $(cat "$RD2/.gitignore") == "steno/" && -f $RD2/steno/steno-$(date +%F).txt ]]'
dfresh; RD3=$W/repo3; rm -rf "$RD3"; mkdir -p "$RD3"; git init -q "$RD3"; printf 'steno-*.txt\n' > "$RD3/.gitignore"
nstart "$RD3" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "the old steno-*.txt line no longer counts: steno/ is added" '[[ $(cat "$RD3/.gitignore") == "$(printf "steno-*.txt\nsteno/")" ]]'

echo "== session audio (notes; live is covered above)"
dfresh; mkdir -p "$W/gate"; export FAKE_FF_ENC_LOG=$W/enc.log; rm -f "$FAKE_FF_ENC_LOG"
mkdir -p "$W/an"; rm -rf "$A" "$W/gate"; mkdir -p "$W/gate"; rm -f "$FAKE_FF_ENC_LOG"
nstart "$W/an" FAKE_ENGINE_TEXT="one|two|three"; nwait 3; nstop
ST=$(sed -n 1p "$DAILY" | grep -oE "^start: [0-9-]+ [0-9:]+" | cut -d" " -f2-); AN=$(date -d "$ST" +%Y-%m-%d-%H%M%S)-notes.opus
check "notes session: one audio file named by start time and mode; start line points to it" '[[ $(ls "$A/audio" | wc -l) == 1 && -s $A/audio/$AN ]] && sed -n 1p "$DAILY" | grep -qE " · notes · $W/an/steno-[0-9-]+\.txt · audio/$AN$" && sed -n 2p "$W/an/steno-$(date +%F).txt" | grep -qE " · audio/$AN$"'
check "notes audio: same encoder settings, 3 x 5 s" 'grep -qE "libopus -b:a 96k .*\| 2880000$" "$W/enc.log"'
"$PY" - <<EOF
import sys, datetime as dt, tempfile, pathlib
from stenographr.audio import pick_path
d = pathlib.Path(tempfile.mkdtemp()); t = dt.datetime(2026,11,9,11,28,50)
p1 = pick_path(d, t, "notes"); assert p1.name == "2026-11-09-112850-notes.opus"
p1.parent.mkdir(); p1.write_text("x")
p2 = pick_path(d, t, "notes"); assert p2.name == "2026-11-09-112850-notes-2.opus", p2.name
assert p1.read_text() == "x"
assert pick_path(d, t, "type").name == "2026-11-09-112850-type.opus"
EOF
check "an existing audio file is never reused (-2) and is left alone" '[[ $? == 0 ]]'
check "decimator 48k->16k: speech band passes, >8 kHz removed, chunking does not matter" '"$PY" - <<EOF
import numpy as np
from stenographr.record import Down3
fs = 48000
def run(f, step):
    x = np.sin(2*np.pi*f*np.arange(fs)/fs).astype(np.float32); d = Down3()
    return np.concatenate([d(x[i:i+step]) for i in range(0, fs, step)])
assert abs(run(1000, 4800)[200:].std() - 0.707) < 0.02
assert run(12000, 4800)[200:].std() < 0.02
assert len(run(1000, 4800)) == 16000 and np.allclose(run(3000, 4800), run(3000, 777), atol=1e-5)
EOF'
dfresh; export FAKE_FF_ENC_FAIL=1
nstart "$W/an2" FAKE_PW_CHUNKS=1 FAKE_ENGINE_TEXT="solo"; nwait 1; nstop
check "notes with a failing encoder: sentences still printed and filed, exit 0, audio FAILED" '[[ $(cat "$W/notes.out") == solo && $(cat "$W/rc") == 0 ]] && grep -qE "· audio: none$" "$DAILY" && tail -1 "$DAILY" | grep -qE "· ok \(audio FAILED, see steno.log\)$" && grep -q "solo" "$W/an2/steno-$(date +%F).txt"'
unset FAKE_FF_ENC_FAIL FAKE_FF_ENC_LOG


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
