#!/usr/bin/env bash
# Offline tests: fake engine, fake nvidia-smi/ffmpeg/ffprobe first on PATH. No model, GPU, network or /data.
HERE=$(dirname "$(readlink -f "$0")"); PROJECT=$(dirname "$HERE")
W=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null; rm -rf "$W"' EXIT

# python with numpy: $STENO_PY, else the uv tool venv, else system python
PY=${STENO_PY:-}
[[ -z $PY && -x $(uv tool dir 2>/dev/null)/stenographr/bin/python ]] && PY=$(uv tool dir)/stenographr/bin/python
[[ -z $PY ]] && PY=python3
"$PY" -c 'import numpy, textual' 2>/dev/null || { echo "need a python with numpy and textual (set STENO_PY)"; exit 2; }

export PATH=$HERE/fakebin:$PATH PYTHONPATH=$PROJECT/src PYTHONDONTWRITEBYTECODE=1
export STENOGRAPHR_CONFIG=$W/config.toml FAKE_SMI_SEQ=
A=$W/archive; OUT=$W/out; LOG=$A/steno.log
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; [[ -n $STENO_TEST_DEBUG ]] && { echo "--- daily:"; cat "$DAILY" 2>/dev/null | cut -c1-120; echo "--- log tail:"; tail -8 "$LOG" 2>/dev/null | cut -c1-150; echo "---"; }; fi; }
mkconf() { printf '[paths]\narchive = "%s"\nmodels = "%s/models"\n[engine]\nname = "fake"\n[device]\nvram_need_mib = 2000\nvram_margin_mib = 500\nmax_gpu_util_pct = 30\nbusy_processes = ["steno-test-busy"]\n%s\n' "$A" "$W" "$1" > "$W/config.toml"; }
steno() { "$PY" -m stenographr.cli "$@"; }
fresh() { rm -rf "$A" "$OUT"; : > "$W/rc"; unset FAKE_SMI FAKE_SMI_FAIL FAKE_ENGINE_FAIL_GPU FAKE_ENGINE_GPU FAKE_FF_FAIL FAKE_FF_NOAUDIO; export FAKE_SMI_SEQ=; }
mkconf ""
mkvid() { mkdir -p "$W/v"; : > "$W/v/$1"; echo "$W/v/$1"; }   # contents don't matter: ffmpeg/ffprobe are fakes
dev_of() { grep -o 'device: [a-z]* (.*)' "$LOG" | head -n${1:-1} | tail -n1; }

echo "== .txt format"
fresh; V=$(mkvid 20261108_063820.mp4)
FAKE_FF_SECONDS=12 FAKE_FF_DURATION=1515.647467 FAKE_ENGINE_SECONDS=5 steno clip "$V" --out "$OUT" --device cpu >/dev/null
M=$OUT/20261108_063820.txt
{ cat <<EOF
# 20261108_063820 · recorded 2026-11-08 06:38 · 00:25:15
source: $V
EOF
} > "$W/exp-head"
check "first two lines exact"   'diff <(sed -n 1,2p "$M") "$W/exp-head"'
check "engine line"             'grep -qxE "engine: fake \(cpu\) · transcribed [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}" <(sed -n 3p "$M")'
check "blank line then segments" '[[ -z $(sed -n 4p "$M") ]]'
cat > "$W/exp-seg" <<'EOF'
[00:00:00 → 00:00:05 | 06:38:20] hello world
[00:00:05 → 00:00:10 | 06:38:25] second line
[00:00:10 → 00:00:12 | 06:38:30] hello world
EOF
check "segment lines exact"     'diff <(sed -n "5,\$p" "$M") "$W/exp-seg"'
check "archive copy identical"  'cmp -s "$M" "$A/clips/clip-2026-11-08-063820.txt"'

echo "== time of day math"
check "offset math incl. hour/midnight wrap" '"$PY" - <<EOF
import datetime as dt
from stenographr.clip import time_of_day, hms
s = dt.datetime(2026,11,8,23,59,58)
assert time_of_day(s, 0) == "23:59:58"
assert time_of_day(s, 5.9) == "00:00:03", time_of_day(s, 5.9)      # floors, wraps midnight
assert time_of_day(dt.datetime(2026,11,8,6,38,20), 3700) == "07:40:00"
assert hms(3725.9) == "01:02:05" and hms(0) == "00:00:00" and hms(1515.64) == "00:25:15"
EOF'
fresh; V=$(mkvid 20261108_235958.mp4)
FAKE_ENGINE_SECONDS=5 steno clip "$V" --out "$OUT" --device cpu >/dev/null
check "midnight crossing in file" 'grep -q "^\[00:00:05 → 00:00:10 | 00:00:03\]" "$OUT/20261108_235958.txt" && grep -q "recorded 2026-11-08 23:59" "$OUT/20261108_235958.txt"'

echo "== one transcript per source file"
fresh; V=$(mkvid 20261108_063820.mp4)
steno clip "$V" --out "$OUT" --device cpu >/dev/null
echo "x" >> "$OUT/20261108_063820.txt"; BEFORE=$(cat "$OUT/20261108_063820.txt")
steno clip "$V" --out "$OUT" --device cpu >"$W/o2" 2>"$W/e2"; echo $? > "$W/rc"
check "second run: exit 1, nothing new written" '[[ $(cat "$W/rc") == 1 && $(find "$OUT" "$A/clips" -type f | wc -l) == 2 && $(cat "$OUT/20261108_063820.txt") == "$BEFORE" ]]'
check "refusal names both paths and the exact rm" 'grep -qxF "stenographr: 20261108_063820.mp4: already transcribed ($OUT/20261108_063820.txt and $A/clips/clip-2026-11-08-063820.txt); to redo it: rm '"'$OUT/20261108_063820.txt' '$A/clips/clip-2026-11-08-063820.txt'"'" "$W/e2"'
check "refusal logged, nothing on stdout" 'grep -q "WARN  20261108_063820.mp4 refused: already transcribed" "$LOG" && [[ ! -s $W/o2 ]]'
eval "$(grep -o "rm '.*'" "$W/e2")"
steno clip "$V" --out "$OUT" --device cpu >/dev/null; echo $? > "$W/rc"
check "after running the printed rm, it transcribes again" '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.txt ]]'
fresh; mkdir -p "$W/sp"; : > "$W/sp/it's 20261108_063820.mp4"
steno clip "$W/sp/it's 20261108_063820.mp4" --out "$OUT" --device cpu >/dev/null; steno clip "$W/sp/it's 20261108_063820.mp4" --out "$OUT" --device cpu 2>"$W/e2" >/dev/null
check "rm line is shell-safe for odd names" 'grep -qF "rm '"'$OUT/it'\\\\''s 20261108_063820.txt'"'" "$W/e2" && (. <(grep -o "rm .*" "$W/e2") && [[ ! -e "$OUT/it'"'"'s 20261108_063820.txt" ]])'
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4); V3=$(mkvid 20261108_081500.mp4)
steno clip "$V2" --out "$OUT" --device cpu >/dev/null
steno clip "$V1" "$V2" "$V3" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "3 videos, 1 already done: other 2 written, exit 1" '[[ $(cat "$W/rc") == 1 && -f $OUT/20261108_063820.txt && -f $OUT/20261108_081500.txt && ! -e $OUT/20261108_070641-2.txt ]]'
fresh; steno clip "$V1" --out "$OUT" --device cpu >/dev/null; rm "$OUT/20261108_063820.txt"
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>"$W/e2"; echo $? > "$W/rc"
check "archive copy alone also triggers a refusal" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.txt && $(find "$A/clips" -type f | wc -l) == 1 ]] && grep -q "already transcribed" "$W/e2" && grep -q "rm .*/clip-2026-11-08-063820.txt" "$W/e2"'
fresh; mkdir -p "$OUT"; echo precious > "$OUT/20261108_063820.txt"
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>&1
check "existing .txt beside the video is untouched, no -2" '[[ $(cat "$OUT/20261108_063820.txt") == precious && ! -e $OUT/20261108_063820-2.txt && ! -e $A/clips ]]'
fresh; V1=$(mkvid 20261108_063820.mp4)
steno clip "$V1" >/dev/null
check "no --out: .txt lands next to the video" '[[ -f $W/v/20261108_063820.txt && -f $A/clips/clip-2026-11-08-063820.txt ]]'

echo "== archive layout and same-second names"
fresh; VA=$(mkvid 20250101_120000.mp4); VB=$(mkvid 20250101_120000_001.mp4)
steno clip "$VA" "$VB" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "same-second pair: both transcribed, exit 0" '[[ $(cat "$W/rc") == 0 && -f $OUT/20250101_120000.txt && -f $OUT/20250101_120000_001.txt ]]'
check "archive: two distinct flat files" '[[ $(find "$A/clips" -type f | wc -l) == 2 && -f $A/clips/clip-2025-01-01-120000.txt && -f $A/clips/clip-2025-01-01-120000_001.txt ]] && head -1 "$A/clips/clip-2025-01-01-120000_001.txt" | grep -q "^# 20250101_120000_001 "'
fresh; V1=$(mkvid 20251127_155055.mp4); V2=$(mkvid 20251127_155055_001.mp4); V3=$(mkvid 20251216_124355_1_1.mp4); V4=$(mkvid some-talk.mp4)
"$PY" -c 'import os; os.utime("'"$V4"'", (1700000000, 1700000000))'
steno clip "$V1" "$V2" "$V3" "$V4" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
EXP4=other/$(date -d @1700000000 '+%Y-%m-%d')-some-talk.txt
check "Samsung names: timestamp, then the rest of the stem as is" '[[ $(cat "$W/rc") == 0 && -f $A/clips/clip-2025-11-27-155055.txt && -f $A/clips/clip-2025-11-27-155055_001.txt && -f $A/clips/clip-2025-12-16-124355_1_1.txt ]]'
check "non-Samsung name: other/<recording date>-<stem>.txt, not in clips/" '[[ -f $A/$EXP4 && ! -e $A/clips/*some-talk* ]]'
check "clips/ holds the 3 Samsung files, other/ the 1; both flat" '[[ $(find "$A/clips" -type f | wc -l) == 3 && $(find "$A/other" -type f | wc -l) == 1 && -z $(find "$A/clips" "$A/other" -mindepth 1 -type d) ]]'
check "no .md anywhere (out dir, archive)" '[[ -z $(find "$OUT" "$A" -name "*.md") ]]'
echo "== no audio stream"
fresh; VN=$(mkvid 20250102_080000.mp4)
FAKE_FF_NOAUDIO=1 steno clip "$VN" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "no audio: exit 0, .txt has header and (no audio) only" '[[ $(cat "$W/rc") == 0 && $(sed -n 5,\$p "$OUT/20250102_080000.txt") == "(no audio)" && $(head -1 "$OUT/20250102_080000.txt") == "# 20250102_080000 · recorded 2025-01-02 08:00 · 00:25:15" ]]'
check "same placeholder in the archive, logged as INFO" 'cmp -s "$OUT/20250102_080000.txt" "$A/clips/clip-2025-01-02-080000.txt" && grep -q "INFO  20250102_080000.mp4 finish: no audio" "$LOG"'
FAKE_FF_NOAUDIO=1 steno clip "$VN" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "second run refuses it" '[[ $(cat "$W/rc") == 1 ]] && grep -q "refused: already transcribed" "$LOG"'

echo "== model loaded once per run"
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4); V3=$(mkvid 20261108_081500.mp4)
export FAKE_ENGINE_COUNT=$W/count; : > "$FAKE_ENGINE_COUNT"
steno clip "$V1" "$V2" "$V3" --out "$OUT" --device cpu >/dev/null
check "3 videos: engine built once" '[[ $(grep -c . "$FAKE_ENGINE_COUNT") == 1 ]] && [[ $(grep -c "engine loaded" "$LOG") == 1 ]] && [[ $(grep -c "timing:" "$LOG") == 3 ]]'
fresh; : > "$FAKE_ENGINE_COUNT"
FAKE_ENGINE_FAIL_GPU=1 steno clip "$V1" "$V2" "$V3" --out "$OUT" >/dev/null; echo $? > "$W/rc"
check "GPU fails: all 3 done on CPU, one GPU attempt + one CPU engine" '[[ $(cat "$W/rc") == 0 && $(ls "$OUT" | wc -l) == 3 && $(grep -c . "$FAKE_ENGINE_COUNT") == 2 ]] && [[ $(grep -c "^cpu$" "$FAKE_ENGINE_COUNT") == 1 ]] && grep -q "(cpu) ·" "$OUT/20261108_081500.txt"'
unset FAKE_ENGINE_COUNT

echo "== recording start fallback order"
fresh
V1=$(mkvid 20261108_063820_1.mp4); V2=$(mkvid camera-clip.mp4); V3=$(mkvid other.mp4)
steno clip "$V1" --out "$OUT" --recorded-at "2020-01-02 03:04" --device cpu >/dev/null
check "Samsung name (with suffix) beats --recorded-at" 'head -1 "$OUT/20261108_063820_1.txt" | grep -q "recorded 2026-11-08 06:38 "'
steno clip "$V2" --out "$OUT" --recorded-at "2020-01-02 03:04" --device cpu >/dev/null
check "--recorded-at used when no timestamp in name"  'head -1 "$OUT/camera-clip.txt" | grep -q "recorded 2020-01-02 03:04 " && grep -q "^\[00:00:00 → 00:00:05 | 03:04:00\]" "$OUT/camera-clip.txt"'
"$PY" -c 'import os; os.utime("'"$V3"'", (1700000000, 1700000000))'
steno clip "$V3" --out "$OUT" --device cpu >/dev/null
EXP=$(date -d @1700000000 '+%Y-%m-%d %H:%M')
check "mtime when nothing else"                       'head -1 "$OUT/other.txt" | grep -q "recorded $EXP "'
V4=$(mkvid 20269999_999999.mp4); steno clip "$V4" --out "$OUT" --recorded-at "2021-05-06 07:08:09" --device cpu >/dev/null
check "impossible Samsung date falls through"         'head -1 "$OUT/20269999_999999.txt" | grep -q "recorded 2021-05-06 07:08 "'
steno clip "$V2" --out "$OUT" --recorded-at "garbage" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "bad --recorded-at is an error, not a guess"    '[[ $(cat "$W/rc") == 1 ]] && grep -q "ERROR.*cannot parse --recorded-at" "$LOG"'

echo "== daily manifest"
TODAY=$(date +%F); MF=$A/steno-$TODAY.txt
fresh; V1=$(mkvid 20261109_083630.mp4); V2=$(mkvid some-talk.mp4); V3=$(mkvid 20261109_090000.mp4)
"$PY" -c 'import os; os.utime("'"$V2"'", (1700000000, 1700000000))'
steno clip "$V1" "$V2" --out "$OUT" --device cpu >/dev/null 2>&1
D2=$(date -d @1700000000 +%F)
LINE='[a-z]+: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} · '
check "manifest is steno-<today>.txt in the archive root" '[[ -f $MF && $(ls "$A"/steno-*.txt | wc -l) == 1 ]]'
check "success, Samsung: clip: time · stem → clips/..." 'grep -qE "^clip: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} · 20261109_083630 → clips/clip-2026-11-09-083630.txt$" "$MF"'
check "success, other: other: time · stem → other/<date>-stem" 'grep -qE "^other: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} · some-talk → other/$D2-some-talk.txt$" "$MF"'
FAKE_FF_FAIL=1 steno clip "$V3" --out "$OUT" --device cpu >/dev/null 2>&1
check "failure line" 'grep -qE "^clip: [0-9-]+ [0-9:]+ · 20261109_090000 · FAILED: see steno.log$" "$MF"'
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>&1
check "refusal line" 'grep -qE "^clip: [0-9-]+ [0-9:]+ · 20261109_083630 · refused: already transcribed$" "$MF"'
check "append only: 4 lines, earlier ones intact" '[[ $(wc -l < "$MF") == 4 && $(head -1 "$MF") == *"20261109_083630 → clips/"* ]]'
steno clip "$V2" --out "$OUT" --device cpu >/dev/null 2>&1
check "refusal of an 'other' file is an other: line" 'grep -qE "^other: [0-9-]+ [0-9:]+ · some-talk · refused: already transcribed$" "$MF"'
fresh; mkdir -p "$A"; mkdir "$A/steno-$TODAY.txt"      # manifest path unwritable (a directory)
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "manifest failure: transcript still written, exit 0, logged" '[[ $(cat "$W/rc") == 0 && -f $OUT/20261109_083630.txt && -f $A/clips/clip-2026-11-09-083630.txt ]] && grep -q "ERROR 20261109_083630.mp4 could not write the daily manifest" "$LOG"'

echo "== .txt -> .srt"
cat > "$W/t.txt" <<'EOF'
# t · recorded 2026-11-08 06:38 · 01:00:00
source: /x/t.mp4
engine: fake (cpu) · transcribed 2026-11-08 10:00

[00:00:00 → 00:00:03 | 06:38:20] First line, with → arrow
[00:00:04 → 00:00:04 | 06:38:24] Zero length
[01:02:05 → 01:02:09 | 07:40:25] Over an hour
EOF
steno srt "$W/t.txt" >/dev/null
cat > "$W/t.srt.exp" <<'EOF'
1
00:00:00,000 --> 00:00:03,000
First line, with → arrow

2
00:00:04,000 --> 00:00:05,000
Zero length

3
01:02:05,000 --> 01:02:09,000
Over an hour
EOF
check "srt content"             'diff "$W/t.srt" "$W/t.srt.exp"'
steno srt "$W/t.txt" >/dev/null
check "srt never overwrites"    '[[ -f $W/t-2.srt ]] && diff "$W/t.srt" "$W/t-2.srt" >/dev/null'
check "clip does not write srt" '[[ -z $(find "$OUT" "$A" -name "*.srt") ]]'

echo "== device selection"
fresh; V=$(mkvid 20261108_063820.mp4)
steno clip "$V" --out "$OUT" >/dev/null
check "free GPU -> gpu"          '[[ $(dev_of) == "device: gpu ("* ]] && grep -q "(gpu) ·" "$OUT/20261108_063820.txt"'
fresh; FAKE_SMI="1000, 5" steno clip "$V" --out "$OUT" >/dev/null
check "not enough VRAM -> cpu"   '[[ $(dev_of) == "device: cpu (free VRAM 1000 MiB < needed 2500 MiB)" ]] && grep -q "(cpu) ·" "$OUT/20261108_063820.txt"'
fresh; FAKE_SMI="3500, 80" steno clip "$V" --out "$OUT" >/dev/null
check "busy GPU util -> cpu"     '[[ $(dev_of) == "device: cpu (GPU busy: utilization 80%"* ]]'
fresh; FAKE_SMI="2500, 29" steno clip "$V" --out "$OUT" >/dev/null
check "boundaries: VRAM == need+margin and util just under -> gpu" '[[ $(dev_of) == "device: gpu ("* ]]'
fresh; FAKE_SMI_FAIL=1 steno clip "$V" --out "$OUT" >/dev/null
check "nvidia-smi errors -> cpu" '[[ $(dev_of) == "device: cpu (nvidia-smi failed)" ]]'
fresh; FAKE_ENGINE_GPU=0 steno clip "$V" --out "$OUT" >/dev/null
check "no CUDA runtime -> cpu"   '[[ $(dev_of) == "device: cpu (installed sherpa-onnx has no CUDA support)" ]]'
# nvidia-smi missing: a PATH holding only the fake ffmpeg/ffprobe
mkdir -p "$W/nosmi"; ln -sf "$HERE/fakebin/ffmpeg" "$HERE/fakebin/ffprobe" "$(command -v head)" "$W/nosmi/"
fresh; PATH=$W/nosmi steno clip "$V" --out "$OUT" >/dev/null
check "nvidia-smi missing -> cpu" '[[ $(dev_of) == "device: cpu (nvidia-smi not found)" ]]'
# busy process: a copy of sleep named like the configured busy process
# (a shell script: the kernel names the process after the script file)
mkdir -p "$W/bin"; printf '#!/bin/sh\nsleep 300\n' > "$W/bin/steno-test-busy"; chmod +x "$W/bin/steno-test-busy"; "$W/bin/steno-test-busy" & BP=$!
sleep 0.2
fresh; steno clip "$V" --out "$OUT" >/dev/null
check "busy process running -> cpu" '[[ $(dev_of) == "device: cpu (busy process running: steno-test-busy)" ]]'
fresh; steno clip "$V" --out "$OUT" --device gpu >/dev/null
check "--device gpu ignores busy list" '[[ $(dev_of) == "device: gpu ("* ]]'
pkill -P $BP; kill $BP; wait $BP 2>/dev/null; sleep 0.1
fresh; steno clip "$V" --out "$OUT" >/dev/null
check "busy process gone -> gpu again" '[[ $(dev_of) == "device: gpu ("* ]]'
fresh; steno clip "$V" --out "$OUT" --device cpu >/dev/null
check "--device cpu with free GPU -> cpu" '[[ $(dev_of) == "device: cpu (--device cpu)" ]]'
check "default busy list has Kdenlive's render processes" '"$PY" -c "from stenographr.config import load; import os; os.environ[\"STENOGRAPHR_CONFIG\"]=\"/nonexistent\"; b=load().busy_processes; assert \"melt\" in b and \"kdenlive_render\" in b, b"'

echo "== checked before EACH file"
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4)
printf '3500, 5\n1000, 5\n' > "$W/seq"
FAKE_SMI_SEQ=$W/seq steno clip "$V1" "$V2" --out "$OUT" >/dev/null
check "file 1 gpu, file 2 cpu"   '[[ $(dev_of 1) == "device: gpu ("* && $(dev_of 2) == "device: cpu (free VRAM 1000"* ]]'

echo "== GPU failure falls back to CPU"
fresh; FAKE_ENGINE_FAIL_GPU=1 steno clip "$V1" --out "$OUT" >/dev/null; echo $? > "$W/rc"
check "exit 0 and output written"  '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.txt ]]'
check "txt says cpu"                'grep -q "^engine: fake (cpu) ·" "$OUT/20261108_063820.txt"'
check "failure logged as ERROR"    'grep -qE "ERROR 20261108_063820.mp4 GPU run failed, redoing on CPU: RuntimeError: fake CUDA failure" "$LOG"'

echo "== log"
fresh; steno clip "$V1" --out "$OUT" >/dev/null
check "lines: time level file message" '! grep -vE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (INFO |WARN |ERROR) [^ ]+ .+$" "$LOG"'
check "start, device, timing, finish"  'grep -q " start: " "$LOG" && grep -q " device: " "$LOG" && grep -q " timing: .*rtf=" "$LOG" && grep -q " finish: " "$LOG"'
fresh; FAKE_FF_FAIL=1 steno clip "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "ffmpeg failure: exit 1, logged with detail, no output" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.txt ]] && grep -q "ERROR 20261108_063820.mp4 RuntimeError: ffmpeg failed (1): fake ffmpeg: Invalid data" "$LOG"'
fresh; steno clip "$W/v/missing.mp4" "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "missing file: error, next file still done" '[[ $(cat "$W/rc") == 1 && -f $OUT/20261108_063820.txt ]] && grep -q "ERROR missing.mp4 FileNotFoundError" "$LOG"'


# ======================================================================= dictation
export XDG_CONFIG_HOME=$W/xdg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # the user's global gitignore must not matter
export XDG_RUNTIME_DIR=$W/run FAKE_PW_LOG=$W/pw.log FAKE_YDOTOOL_LOG=$W/ydo.log FAKE_CLIP=$W/clip FAKE_GSETTINGS=$W/gs
dfresh() { fresh; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null; rm -rf "$XDG_RUNTIME_DIR" "$W/pw.log" "$W/ydo.log" "$W/clip" "$W/gate"; unset HB_CLAUDE_PANE TMUX_PANE FAKE_TMUX_SESSENV FAKE_TMUX_SESSION FAKE_MIC_MISSING FAKE_PW_FAIL FAKE_YDOTOOL_FAIL FAKE_ENGINE_TEXT FAKE_ENGINE_SECONDS FAKE_PW_GATE FAKE_PW_CHUNKS FAKE_ENGINE_LOAD_DELAY FAKE_ENGINE_CLEAN_TEXT FAKE_ENGINE_CLEAN_SECONDS FAKE_ENGINE_CLEAN_FAIL FAKE_TMUX_CLIENTS FAKE_TMUX_PANES FAKE_TMUX_SEND_FAIL; rm -f "$W/tmux.log" "$W/kitty.log" "$W/wmctrl.log" "$W/wlcopy.log" "$W/sig"; unset FAKE_WLCOPY_HOLD; }
DAILY=$A/steno-$(date +%F).txt
BLK='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'

waitfor() { local i; for i in $(seq ${2:-120}); do eval "$1" && return 0; sleep 0.05; done; return 1; }
ydo_n() { local n; n=$(grep -c . "$W/ydo.log" 2>/dev/null); echo "${n:-0}"; }
endn() { local n; n=$(grep -c '^end:' "$DAILY" 2>/dev/null); echo "${n:-0}"; }
plus() { date -d "$(date +%F) $1 $2 seconds" +%T; }            # plus HH:MM:SS N -> HH:MM:SS + N seconds
TS='\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]'

export FAKE_TMUX_LOG=$W/tmux.log FAKE_KITTY_LOG=$W/kitty.log FAKE_WMCTRL_LOG=$W/wmctrl.log FAKE_WLCOPY_LOG=$W/wlcopy.log
LIVEARGS="live --popup --headless --device cpu"
lpy() { "$PY" - "$@"; }                                   # python with the stenographr package + this test's env
LPRE='
import os, sys, time, threading, datetime as dt, asyncio
from stenographr.config import load
from stenographr.log import Log
from stenographr.live import LiveSession
cfg = load(); log = Log(cfg.archive / "steno.log"); W = os.environ["W"]
def wait(cond, secs=8):
    t = time.time()
    while time.time() - t < secs:
        if cond(): return
        time.sleep(0.05)
    raise SystemExit("timeout waiting for a condition")
def go(n): open(f"{W}/gate/go{n}", "w").close()
def start():
    s = LiveSession(cfg, log, "cpu"); s.phrases = []; s.on_phrase = s.phrases.append
    assert s.preflight() is None
    s.record_thread = threading.Thread(target=s.record); s.record_thread.start(); return s
def daily_text(): return open(sorted(__import__("glob").glob(str(cfg.archive / "steno-*.txt")))[-1]).read()
'
export W
CLEANENV="FAKE_ENGINE_TEXT=one|two|three FAKE_ENGINE_CLEAN_TEXT=Clean_{secs}_seconds. FAKE_ENGINE_CLEAN_SECONDS=100"
runcore() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds. Second sentence." FAKE_ENGINE_CLEAN_SECONDS=100; "$PY" -c "$LPRE
$1" ); }

echo "== live --toggle (popups only) and the instance registry"
REG=$XDG_RUNTIME_DIR/stenographr/live
fakeinst() {   # fakeinst NAME KIND RECORDING WHERE: a stand-in instance (counts the SIGUSR1s it gets), registered
  mkdir -p "$REG"; bash -c "trap 'echo got >> $W/sig.$1' USR1; while :; do sleep 0.05; done" stenographr live & FPID=$!
  printf '{"pid": %s, "kind": "%s", "where": "%s", "recording": %s, "started": 0}' "$FPID" "$2" "$4" "$3" > "$REG/$FPID.json"; sleep 0.15
}
dfresh
steno live --toggle; echo $? > "$W/rc"
check "no popup open: kitty is launched once, 80x25 cells, titled, size not remembered, running 'stenographr live --popup'" '[[ $(cat "$W/rc") == 0 && $(grep -c . "$W/kitty.log") == 1 ]] && grep -qF -- "--title|stenographr live|" "$W/kitty.log" && grep -qF -- "-o|initial_window_width=80c|-o|initial_window_height=25c|-o|remember_window_size=no|" "$W/kitty.log" && grep -qE "\|-m\|stenographr.cli\|live\|--popup\|$" "$W/kitty.log"'
waitfor '[[ -s $W/wmctrl.log ]]'
check "the popup opens under XWayland (-o linux_display_server=x11) and gets marked always-on-top (wmctrl -r <title> -b add,above)" 'grep -qF -- "linux_display_server=x11" "$W/kitty.log" && grep -qxF -- "-r|stenographr live|-b|add,above|" "$W/wmctrl.log"'
steno live --toggle
check "pressed again before the popup has registered: no second window" '[[ $(grep -c . "$W/kitty.log") == 1 ]]'
dfresh; mkdir -p "$REG"; echo '{"pid": 999999, "kind": "popup", "where": "popup", "recording": true, "started": 0}' > "$REG/999999.json"
steno live --toggle
check "a stale registry entry (its process is gone) is ignored and removed: kitty is launched" '[[ $(grep -c . "$W/kitty.log") == 1 && ! -e $REG/999999.json ]]'
dfresh; rm -f "$W"/sig.*; fakeinst pop popup true popup; PP=$FPID
steno live --toggle; waitfor '[[ -s $W/sig.pop ]]'
check "a popup is recording: Ctrl+backtick stops it (SIGUSR1), no window opened" '[[ $(cat "$W/sig.pop") == got && ! -e $W/kitty.log ]]'
rm -f "$W/sig.pop"; printf '{"pid": %s, "kind": "popup", "where": "popup", "recording": false, "started": 0}' "$PP" > "$REG/$PP.json"
steno live --toggle; sleep 0.4
check "that popup is now at its button step: Ctrl+backtick raises it (wmctrl -a by its title), no stop signal, no new window" '[[ ! -e $W/sig.pop && ! -e $W/kitty.log ]] && grep -qxF -- "-a|stenographr live|" "$W/wmctrl.log"'
rm -f "$W/wmctrl.log"; printf '{"pid": %s, "kind": "popup", "where": "popup", "recording": true, "started": 0}' "$PP" > "$REG/$PP.json"
steno live --toggle; waitfor '[[ -s $W/sig.pop ]]'
check "the popup is recording again: Ctrl+backtick stops it and does not raise it" '[[ $(cat "$W/sig.pop") == got && ! -e $W/wmctrl.log ]]'
kill $PP 2>/dev/null; wait $PP 2>/dev/null
dfresh; rm -f "$W"/sig.*; fakeinst ready loop false alpha; L1=$FPID; fakeinst rec loop true beta; L2=$FPID
steno live --toggle; sleep 0.4
check "pane instances (one ready, one recording) are never touched: no signals; a popup is opened since none exists" '[[ ! -e $W/sig.ready && ! -e $W/sig.rec && $(grep -c . "$W/kitty.log") == 1 ]]'
kill $L1 $L2 2>/dev/null; wait $L1 $L2 2>/dev/null
dfresh; mkdir -p "$REG"; echo '{"pid": 999998, "kind": "loop", "where": "x", "recording": true, "started": 0}' > "$REG/999998.json"; fakeinst keep loop false x; K=$FPID
check "registry: stale entries are cleaned when read, live ones kept" '"$PY" - <<EOF
from stenographr import registry
ids = [i["pid"] for i in registry.instances()]
assert ids == [$K], ids
import os; assert not os.path.exists("$REG/999998.json")
EOF'
kill $K 2>/dev/null; wait $K 2>/dev/null

echo "== live session (core): live lines, clean pass, choices"
dfresh; mkdir -p "$W/gate"; export FAKE_FF_ENC_LOG=$W/enc.log; rm -f "$FAKE_FF_ENC_LOG"
runcore '
s = start()
wait(lambda: s.phrases == ["one"])
txt = daily_text()
assert "] one" in txt and "clean:" not in txt and "\nend:" not in txt, txt      # on screen AND in the daily file before stop
go(2); wait(lambda: len(s.phrases) == 2); go(3); wait(lambda: len(s.phrases) == 3)
s.request_stop(); s.record_thread.join(10); assert not s.record_thread.is_alive()
print("CLEAN:", s.clean())
print("STATUS:", s.deliver("copy"))
' > "$W/core.out" 2>&1
check "phrases are shown as recognised and already appended to the daily file (before the stop)" 'grep -q "^CLEAN:" "$W/core.out"'
check "the clean pass ran on the whole saved audio (15 s = 3 x 5 s at 16 kHz), not on the phrases" 'grep -qx "CLEAN: Clean 15 seconds. Second sentence." "$W/core.out"'
T0=$(sed -n 1p "$DAILY" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2} ·" | cut -d" " -f1)
check "daily block: start (live · unknown · audio), 3 timestamped live lines, clean: + timestamped clean lines, end ok · copied" '[[ $(sed -n 1p "$DAILY") =~ ^start:\ $BLK\ ·\ live\ ·\ unknown\ ·\ audio/[0-9-]+-live\.opus$ ]] && sed -n 2p "$DAILY" | grep -qx "\[$T0\] one" && sed -n 4p "$DAILY" | grep -qx "\[$(plus $T0 10)\] three" && sed -n 5p "$DAILY" | grep -qx "clean:" && sed -n 6p "$DAILY" | grep -qE "^$TS Clean 15 seconds\." && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · copied$"'
check "Copy: wl-copy got the clean text (no timestamps) plus ONE trailing space" '[[ $(cat "$W/clip") == "Clean 15 seconds. Second sentence. " ]]'
check "STATUS printed is the end line status" 'grep -qx "STATUS: ok · copied" "$W/core.out"'
ST=$(sed -n 1p "$DAILY" | grep -oE "^start: [0-9-]+ [0-9:]+" | cut -d" " -f2-); AF=$(date -d "$ST" +%Y-%m-%d-%H%M%S)-live.opus
check "audio: exactly one file named session start + mode (live), pointed to by the start line" '[[ $(ls "$A/audio" | wc -l) == 1 && -s $A/audio/$AF ]] && sed -n 1p "$DAILY" | grep -qE " · live · unknown · audio/$AF$"'
check "encoder was given mono 48 kHz Opus at 96 kbps and exactly the voice channel (3 x 5 s mono f32)" 'grep -qE "^-hide_banner .*-f f32le -ar 48000 -ac 1 -i - -c:a libopus -b:a 96k .* [^ ]+/audio/$AF \| 2880000$" "$W/enc.log"'

dfresh; mkdir -p "$W/gate"
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("new"))' > "$W/core.out" 2>&1
check "New: nothing is delivered, end line says new take" '[[ ! -e $W/clip ]] && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null && grep -qx "STATUS: ok · new take" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · new take$"'
dfresh; mkdir -p "$W/gate"
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("close"))' > "$W/core.out" 2>&1
check "Close: nothing is delivered, end line says closed" '[[ ! -e $W/clip ]] && grep -qx "STATUS: ok · closed" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · closed$"'
dfresh; mkdir -p "$W/gate"
FAKE_MIC_MISSING=1 runcore 's = LiveSession(cfg, log, "cpu"); print("PRE:", s.preflight())' > "$W/core.out" 2>&1
check "mic missing: nothing recorded, daily block FAILED: mic scarlett-mic not found, no audio" 'grep -qx "PRE: mic scarlett-mic not found" "$W/core.out" && [[ ! -e $W/pw.log && ! -e $A/audio ]] && grep -qE "^start: $BLK · live · unknown$" "$DAILY" && grep -qE "^end: $BLK · [0-9]+s · FAILED: mic scarlett-mic not found, see steno.log$" "$DAILY"'
dfresh; mkdir -p "$W/gate"; export FAKE_FF_ENC_FAIL=1
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("copy"))' > "$W/core.out" 2>&1
check "encoder fails: the session still runs and delivers (clipboard set)" '[[ -s $W/clip ]] && grep -q "^STATUS:" "$W/core.out"'
check "encoder fails: start line says audio: none, end line says audio FAILED" 'sed -n 1p "$DAILY" | grep -qE "^start: $BLK · live · unknown · audio: none$" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok \(audio FAILED, see steno.log\) · copied$"'
check "encoder fails: logged with the reason; no audio file" 'grep -q "ERROR live audio not saved .*ffmpeg exited at start .*Permission denied" "$LOG" && [[ ! -e $A/audio || -z $(ls -A "$A/audio") ]]'
unset FAKE_FF_ENC_FAIL FAKE_FF_ENC_LOG

echo "== live: Send to Claude (tmux)"
export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore '
from stenographr import tmuxsend
default, pane, panes, note = tmuxsend.choose_target()
print("TARGET:", default, pane, sorted(panes), note)
s = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean()
print("STATUS:", s.deliver("send", default, pane))
' > "$W/core.out" 2>&1
check "HB_CLAUDE_PANE in our environment, pane exists: that pane is the target (its session), no picker" 'grep -qx "TARGET: alpha %0 \[.alpha., .beta.\] None" "$W/core.out"'
check "Send: the text on ONE line (no trailing space) in one send-keys -l call to alpha's pane (%0), then exactly one Enter key, in that order" '[[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 ]] && [[ $(grep "^send-keys|" "$W/tmux.log" | sed -n 1p) == "send-keys|-t|%0|-l|--|Clean 15 seconds. Second sentence.|" && $(grep "^send-keys|" "$W/tmux.log" | sed -n 2p) == "send-keys|-t|%0|Enter|" ]]'
check "end line: sent to claude alpha; nothing on the clipboard" '[[ ! -e $W/clip ]] && grep -qx "STATUS: ok · sent to claude alpha" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · sent to claude alpha$"'
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("append", "alpha"))' > "$W/core.out" 2>&1
check "Append: the text plus ONE trailing space in one send-keys -l call, and NO Enter" '[[ $(grep -c "^send-keys|" "$W/tmux.log") == 1 ]] && grep -qxF "send-keys|-t|%0|-l|--|Clean 15 seconds. Second sentence. |" "$W/tmux.log" && ! grep -qi "enter" "$W/tmux.log"'
check "end line: appended to claude alpha" 'grep -qx "STATUS: ok · appended to claude alpha" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · appended to claude alpha$"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_SEND_FAIL=1 HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runcore 's = start(); wait(lambda: s.phrases == ["one"]); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("send", "alpha"))' > "$W/core.out" 2>&1
check "tmux send fails: end line FAILED: send to claude failed, logged" 'grep -qx "STATUS: FAILED: send to claude failed, see steno.log" "$W/core.out" && grep -q "ERROR live send to claude alpha failed" "$LOG"'
unset FAKE_TMUX_SEND_FAIL
dfresh; export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "nothing set (not in hyperbeam): no target; the picker list holds the sessions that have a claude pane" 'grep -qx "TARGET: None None \[.alpha., .beta.\] None" "$W/core.out"'
export FAKE_TMUX_PANES='gamma\t%5\tbash\nbeta\t%2\tclaude'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "nothing set, one other session has a claude pane: the picker lists it" 'grep -qx "TARGET: None None \[.beta.\] None" "$W/core.out"'
export FAKE_TMUX_PANES='alpha\t%0\tbash'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "no claude pane anywhere: no target" 'grep -qx "TARGET: None None \[\] None" "$W/core.out"'
export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
export TMUX_PANE=%9 FAKE_TMUX_SESSION=beta FAKE_TMUX_SESSENV='HB_CLAUDE_PANE=%2'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "only the session environment has it (our pane's session -> show-environment): same, pane %2, session beta, no picker" 'grep -qx "TARGET: beta %2 \[.alpha., .beta.\] None" "$W/core.out" && grep -q "^show-environment|-t|beta|HB_CLAUDE_PANE|" "$W/tmux.log"'
export HB_CLAUDE_PANE=%0
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "the environment variable wins over the session environment" 'grep -qx "TARGET: alpha %0 \[.alpha., .beta.\] None" "$W/core.out"'
export HB_CLAUDE_PANE=%77
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "stale id: the notice 'hyperbeam's Claude pane not found', no target (picker)" 'grep -qx "TARGET: None None \[.alpha., .beta.\] hyperbeam.s Claude pane not found" "$W/core.out"'
unset HB_CLAUDE_PANE TMUX_PANE FAKE_TMUX_SESSION FAKE_TMUX_SESSENV
unset HB_CLAUDE_PANE

echo "== live screen (Textual, headless pilot)"
UPRE='
from stenographr.live_ui import LiveApp, PickSession
async def until(pilot, cond, secs=8):
    t = time.time()
    while time.time() - t < secs:
        if cond(): return
        await pilot.pause(0.05)
    raise SystemExit("timeout")
async def click(pilot, sel):
    await pilot.pause(0.25)                       # let the button grid settle before clicking
    await pilot.click(sel)
def labels(app): return {b.id: (str(b.label), b.disabled, b.display) for b in app.screen.query("Button")}
def logtext(app): return [("".join(s.text for s in l)).strip() for l in app.query_one("RichLog").lines]
'
runui() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100; "$PY" -c "$LPRE$UPRE
$1" ); }
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"])
        print("BANNER:", app.screen.query_one("#banner_l").content)
        print("RECORDING:", logtext(app), {k: v[2] for k, v in labels(app).items()})
        go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop")
        await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", logtext(app), labels(app))
        print("BANNER-R:", app.screen.query_one("#banner_r").content)
        await click(pilot, "#send")
        await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "screen: banner text, each phrase shown as recognised, only Stop visible while recording" 'grep -q "^BANNER: Live preview · final text is cleaned up when you stop" "$W/ui.out" && grep -q "^RECORDING: \[.one.\] {.start.: False, .stop.: True, .copy.: False, .append.: False, .send.: False, .new.: False, .close.: False, .stopit.: False, .cancel.: False}" "$W/ui.out"'
check "popup, after Stop: the clean text and exactly Copy, Claude append (a), Claude send (e), Close (no New); the project name is at the right end of the bar" 'grep -q "^REVIEW: \[.Clean 15 seconds..\]" "$W/ui.out" && grep -q ".append.: (.Claude append (a)., False, True)" "$W/ui.out" && grep -q ".send.: (.Claude send (e)., False, True)" "$W/ui.out" && grep -qF "Close (q / Esc)" "$W/ui.out" && grep -q ".new.: (.New (r)., False, False)" "$W/ui.out" && grep -qx "BANNER-R: alpha" "$W/ui.out"'
check "clicking Claude send: the text typed to %0, then one Enter; the window exits; end line sent to claude alpha" 'grep -q "^EXITED" "$W/ui.out" && [[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 ]] && grep -qxF "send-keys|-t|%0|-l|--|Clean 15 seconds.|" "$W/tmux.log" && grep -qxF "send-keys|-t|%0|Enter|" "$W/tmux.log" && tail -1 "$DAILY" | grep -qE "· ok · sent to claude alpha$"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_PANES='alpha\t%0\tbash'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        print("CLAUDE:", labels(app)["append"], labels(app)["send"])
        await pilot.press("a"); await pilot.press("e"); await pilot.pause(0.2); print("PHASE-AFTER-AE:", app.phase)
        await pilot.press("y"); await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "no claude pane: both Claude buttons are disabled (and their keys do nothing)" 'grep -q "^CLAUDE: (.Claude append (a)., True, True) (.Claude send (e)., True, True)" "$W/ui.out" && grep -q "^PHASE-AFTER-AE: review" "$W/ui.out" && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null'
check "the keys work too: s stops, y copies the clean text" 'grep -q "^EXITED" "$W/ui.out" && [[ $(cat "$W/clip") == "Clean 15 seconds. " ]] && tail -1 "$DAILY" | grep -qE "· ok · copied$"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("CLAUDE:", labels(app)["append"][0])
        await click(pilot, "#append"); await pilot.pause(0.3)
        print("PICKER:", type(app.screen).__name__, [str(o.prompt) for o in app.screen.query_one("OptionList").options])
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "ambiguous (two clients): Claude append opens a list of sessions with a claude pane; picking beta appends there (text + space, no Enter)" 'grep -q "^CLAUDE: Claude append (a)" "$W/ui.out" && grep -q "^PICKER: PickSession \[.alpha., .beta.\]" "$W/ui.out" && grep -q "^EXITED" "$W/ui.out" && grep -qxF "send-keys|-t|%2|-l|--|Clean 15 seconds. |" "$W/tmux.log" && ! grep -qi "enter" "$W/tmux.log" && tail -1 "$DAILY" | grep -qE "· ok · appended to claude beta$"'

dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%77 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("STATUS:", app.screen.query_one("#status").content)
        await click(pilot, "#append"); await pilot.pause(0.3)
        print("PICKER:", type(app.screen).__name__)
        await pilot.press("escape"); await pilot.pause(0.2)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "UI, stale id: status shows hyperbeam's Claude pane not found, Append opens the picker" 'grep -q "^STATUS: .*hyperbeam.s Claude pane not found" "$W/ui.out" && grep -q "^PICKER: PickSession" "$W/ui.out"'
unset HB_CLAUDE_PANE

echo "== live loop (pane / terminal instance)"
UPRE2='
def status(app): return str(app.query_one("#status").content)
def last(app): return str(app.query_one("#last").content)
def shown(app): return [b.id for b in app.screen.query("Button") if b.display]
'
runui2() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100 FAKE_ENGINE_COUNT=$W/count; "$PY" -c "$LPRE$UPRE$UPRE2
$1" ); }
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.pause(0.6)
        print("READY:", status(app), shown(app), "| last:", repr(last(app)), "| mic opened:", os.path.exists(W + "/pw.log"))
        go(2); go(3)
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3)
        print("RECORDING:", shown(app), "| mic opened:", os.path.exists(W + "/pw.log"))
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", shown(app), "|", labels(app)["append"][0], "|", labels(app)["send"][0], "|", app.screen.query_one("#banner_r").content)
        await pilot.press("y"); await until(pilot, lambda: app.phase == "ready")
        print("AFTER-COPY:", status(app), "|", last(app))
        await pilot.press("enter"); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        await click(pilot, "#send"); await until(pilot, lambda: app.phase == "ready")
        print("AFTER-SEND:", status(app), "|", last(app))
        await pilot.press("q"); await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "loop starts on Ready, mic closed (no recorder), buttons Start and Close, nothing in the last line" 'grep -q "^READY: Ready \[.start., .close.\] | last: .. | mic opened: False" "$W/ui.out"'
check "Start (r) records: only Stop shown, the recorder is opened now" 'grep -q "^RECORDING: \[.stop.\] | mic opened: True" "$W/ui.out"'
check "button step (loop): Copy, Claude append (a), Claude send (e), New, Close; project name on the bar" 'grep -q "^REVIEW: \[.copy., .append., .send., .new., .close.\] | Claude append (a) | Claude send (e) | alpha" "$W/ui.out"'
check "after Copy: back on Ready with 'Last: copied · HH:MM'; after Send: 'Last: sent to claude alpha · HH:MM'" 'grep -qE "^AFTER-COPY: Ready \| Last: copied · [0-9]{2}:[0-9]{2}$" "$W/ui.out" && grep -qE "^AFTER-SEND: Ready \| Last: sent to claude alpha · [0-9]{2}:[0-9]{2}$" "$W/ui.out" && grep -q "^EXITED" "$W/ui.out"'
check "two captures: two session blocks (end words copied / sent to claude alpha), two audio files, the typed text + one Enter, the clipboard has the clean text plus a space" '[[ $(grep -c "^start:" "$DAILY") == 2 && $(ls "$A/audio" | wc -l) == 2 ]] && grep -qE "· ok · copied$" "$DAILY" && grep -qE "· ok · sent to claude alpha$" "$DAILY" && [[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 && $(cat "$W/clip") == "Clean 15 seconds. " ]]'
check "the model was constructed ONCE for the whole app (two captures)" '[[ $(grep -c . "$W/count") == 1 ]] && [[ $(grep -c "engine loaded" "$LOG") == 1 ]]'
check "no 'no running event loop' anywhere in the log (a capture ending and another beginning)" '! grep -q "no running event loop" "$LOG" && ! grep -q "ERROR" "$LOG"'
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); go(2); go(3)
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3); await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        await pilot.press("r"); await until(pilot, lambda: app.phase == "ready")
        print("AFTER-NEW:", status(app), "|", last(app))
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3); await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        await pilot.press("escape"); await pilot.pause(0.3)
    print("EXITED-AT-BUTTONS")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "New (r) delivers nothing and returns to Ready: 'Last: new take'" 'grep -qE "^AFTER-NEW: Ready \| Last: new take · [0-9]{2}:[0-9]{2}$" "$W/ui.out" && [[ ! -e $W/clip ]] && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null'
check "Close (Esc) at the button step delivers nothing and quits: end line 'closed'; the first block ended 'new take'" 'grep -q "^EXITED-AT-BUTTONS" "$W/ui.out" && [[ $(grep -c "^start:" "$DAILY") == 2 ]] && grep -qE "· ok · new take$" "$DAILY" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · closed$" && [[ ! -e $W/clip ]]'
dfresh; : > "$W/count"
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.press("q"); await pilot.pause(0.3)
    print("EXITED-FROM-READY")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "Close on Ready quits, no session block written, the recorder never started" 'grep -q "^EXITED-FROM-READY" "$W/ui.out" && [[ ! -e $DAILY && ! -e $W/pw.log ]]'
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export FAKE_ENGINE_LOAD_DELAY=1.2
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); go(2); go(3)
        await pilot.press("r")                                      # Start BEFORE the (slow) preload has finished
        await until(pilot, lambda: len(logtext(app)) == 3, 12); print("PHRASES-AFTER-LOAD:", logtext(app))
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.press("q"); await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
unset FAKE_ENGINE_LOAD_DELAY
check "Start before the model has loaded: all the audio is kept (3 phrases), still one model load" 'grep -q "^PHRASES-AFTER-LOAD: \[.one., .two., .three.\]" "$W/ui.out" && [[ $(grep -c . "$W/count") == 1 ]]'
dfresh; mkdir -p "$W/gate"; mkdir -p "$REG"; echo '{"pid": 999997, "kind": "popup", "where": "popup", "recording": true, "started": 0}' > "$REG/999997.json"
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); go(2); go(3); await pilot.press("r")
        await until(pilot, lambda: app.phase == "recording"); print("STALE-IGNORED:", app.phase)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.press("q"); await pilot.pause(0.3)
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "a stale 'recording' entry does not block Start: no notice, records, the entry is cleaned" 'grep -q "^STALE-IGNORED: recording" "$W/ui.out" && [[ ! -e $REG/999997.json ]]'

dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude' FAKE_PANE_FILE=$W/pane
printf 'take1\ntake2\ntake3\n' > "$W/seq"; rm -f "$W/pane"
FAKE_ENGINE_CLEAN_SEQ=$W/seq runui2 '
async def take(pilot, app):
    await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3)
    await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); go(2); go(3)
        await take(pilot, app)
        await pilot.press("s"); await pilot.press("enter"); await pilot.pause(0.3)          # neither may deliver anything
        print("S-AND-ENTER:", app.phase, "| pane so far:", repr(open(W + "/pane").read() if os.path.exists(W + "/pane") else ""))
        await pilot.press("a"); await until(pilot, lambda: app.phase == "ready")
        await take(pilot, app); await pilot.press("a"); await until(pilot, lambda: app.phase == "ready")
        await take(pilot, app); await pilot.press("e"); await until(pilot, lambda: app.phase == "ready")
        print("PANE:", repr(open(W + "/pane").read())); await pilot.press("q"); await pilot.pause(0.3)
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "at the button step s and Enter do nothing (no delivery, still at the buttons)" 'grep -q "^S-AND-ENTER: review | pane so far: ..$" "$W/ui.out"'
check "Append, Append, Send: the stand-in pane gets 'take1 take2 take3' and exactly one Enter, at the very end" 'grep -qxF "PANE: '"'"'take1 take2 take3<ENTER>'"'"'" "$W/ui.out" && [[ $(grep -c "|Enter|" "$W/tmux.log") == 1 && $(grep -c "^send-keys|" "$W/tmux.log") == 4 ]]'
check "end words: appended to claude alpha (x2), then sent to claude alpha; three blocks" '[[ $(grep -c "^start:" "$DAILY") == 3 && $(grep -c "· ok · appended to claude alpha$" "$DAILY") == 2 && $(grep -c "· ok · sent to claude alpha$" "$DAILY") == 1 ]]'
unset FAKE_PANE_FILE

echo "== live screen adapts to the terminal size (tall sidebar ... wide pane)"
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
def misfit(app, w, h):
    bad = []
    for b in app.screen.query("Button"):
        if not b.display: continue
        r = b.region
        if r.x < 0 or r.right > w or r.bottom > h or r.width < len(str(b.label)): bad.append((b.id, str(b.label), tuple(r)))
    br = app.screen.query_one("#banner_r")
    if str(br.content) and (br.region.right > w or br.region.width < len(str(br.content))): bad.append(("banner_r", tuple(br.region)))
    return bad
async def one(w, h):
    app = LiveApp(cfg, log, "cpu"); bad = []
    async with app.run_test(size=(w, h)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.pause(0.1); bad += misfit(app, w, h)
        go(2); go(3)
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3); await pilot.pause(0.1); bad += misfit(app, w, h)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.pause(0.2); bad += misfit(app, w, h)
        shown_n = len([b for b in app.screen.query("Button") if b.display])
        await pilot.press("q"); await pilot.pause(0.2)
    print(f"SIZE {w}x{h}: buttons at review={shown_n} misfits={bad}")
async def main():
    for w, h in ((28, 40), (36, 30), (60, 25), (80, 25), (120, 20)): await one(w, h)
asyncio.run(main())
' > "$W/ui.out" 2>&1
[[ -n $STENO_TEST_DEBUG ]] && cat "$W/ui.out"
for sz in 28x40 36x30 60x25 80x25 120x20; do
  check "terminal $sz: every visible button fits inside the screen with its whole label (ready, recording, button step); 5 buttons at the button step" 'grep -q "^SIZE '"$sz"': buttons at review=5 misfits=\[\]$" "$W/ui.out"'
done

echo "== live popup"
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "recording"); go(2); go(3)
        await until(pilot, lambda: os.path.exists(W + "/pw.log"))
        print("RECORDING:", app.phase, shown(app), "| mic opened:", os.path.exists(W + "/pw.log"))
        await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", shown(app), labels(app)["close"][0])
        await pilot.press("y"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "popup records immediately (no Ready screen), then Stop shows Copy, Claude append, Claude send, Close" 'grep -q "^RECORDING: recording \[.stop.\] | mic opened: True" "$W/ui.out" && grep -q "^REVIEW: \[.copy., .append., .send., .close.\] Close (q / Esc)" "$W/ui.out"'
check "popup exits after the choice (Copy): one block, end line copied" 'grep -q "^EXITED" "$W/ui.out" && [[ $(grep -c "^start:" "$DAILY") == 1 && $(cat "$W/clip") == "Clean 15 seconds. " ]] && tail -1 "$DAILY" | grep -qE "· ok · copied$"'
dfresh; mkdir -p "$W/gate"
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "recording"); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.press("escape"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "popup Close (Esc): delivers nothing, end line closed, exits" 'grep -q "^EXITED" "$W/ui.out" && [[ ! -e $W/clip ]] && tail -1 "$DAILY" | grep -qE "· ok · closed$"'

echo "== one recording at a time (notice)"
export FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100
dfresh; mkdir -p "$W/gate"; rm -f "$W"/sig.*; : > "$W/count"
FAKE_PW_GATE=$W/gate "$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & AP=$!     # instance A: a real popup, recording
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")                                      # instance B: a loop in this process
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.press("r")
        await until(pilot, lambda: app.phase == "notice")
        print("NOTICE:", status(app), shown(app), [str(b.label) for b in app.screen.query("Button") if b.display])
        await click(pilot, "#stopit")
        await until(pilot, lambda: app.phase == "recording", 25); print("B-RECORDING:", app.phase)
        go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.press("q"); await pilot.pause(0.3)
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "Start while another instance records: the notice 'Recording in popup. Stop it and record here?' with Stop it / Cancel" 'grep -q "^NOTICE: Recording in popup. Stop it and record here? \[.stopit., .cancel.\] \[.Stop it and record here (y). *, .Cancel (n).\]" "$W/ui.out"'
check "Stop it: the other instance stopped (it reached its button step: clean block, NO end line, still running) and this one records" 'grep -q "^B-RECORDING: recording" "$W/ui.out" && kill -0 $AP 2>/dev/null && [[ $(grep -c "^clean:" "$DAILY") -ge 1 ]] && [[ $(grep -c "^start:" "$DAILY") == 2 ]] && [[ $(grep -c "^end:" "$DAILY") == 1 ]]'
check "that other instance's registry entry says it is no longer recording, and nothing in the log complains" 'grep -q "\"recording\": false" "$REG/$AP.json" && ! grep -q "no running event loop" "$LOG" && ! grep -q "ERROR" "$LOG"'
kill -HUP $AP; wait $AP 2>/dev/null
check "closing that popup window afterwards ends its block cleanly (not copied, window closed)" 'grep -qE "· ok · not copied \(window closed\)$" "$DAILY"'
dfresh; mkdir -p "$W/gate"; : > "$W/count"
FAKE_PW_GATE=$W/gate "$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & AP=$!
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu")
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.press("r"); await until(pilot, lambda: app.phase == "notice")
        await click(pilot, "#cancel"); await until(pilot, lambda: app.phase == "ready")
        print("CANCELLED:", status(app), shown(app)); await pilot.press("q"); await pilot.pause(0.3)
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "Cancel: this instance goes back to Ready; the other keeps recording (no clean block, registry still recording)" 'grep -q "^CANCELLED: Ready \[.start., .close.\]" "$W/ui.out" && kill -0 $AP 2>/dev/null && ! grep -q "^clean:" "$DAILY" && grep -q "\"recording\": true" "$REG/$AP.json" && [[ $(grep -c "^start:" "$DAILY") == 1 ]]'
kill -HUP $AP; wait $AP 2>/dev/null
dfresh; mkdir -p "$W/gate"; rm -f "$W"/sig.*; fakeinst rec loop true beta; L=$FPID
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)                            # a popup opening while a pane instance records
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "notice")
        print("POPUP-NOTICE:", status(app)); await click(pilot, "#cancel"); await pilot.pause(0.4)
    print("POPUP-EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "popup opening while a pane instance records: notice names its tmux session; Cancel closes the popup; the pane instance got no signal" 'grep -q "^POPUP-NOTICE: Recording in beta. Stop it and record here?" "$W/ui.out" && grep -q "^POPUP-EXITED" "$W/ui.out" && [[ ! -e $W/sig.rec && ! -e $W/pw.log ]]'
kill $L 2>/dev/null; wait $L 2>/dev/null
unset FAKE_ENGINE_TEXT FAKE_ENGINE_CLEAN_TEXT FAKE_ENGINE_CLEAN_SECONDS

dfresh; export FAKE_WLCOPY_HOLD=4
T1=$(date +%s); OUTC=$("$PY" -c "from stenographr import dictate, recall; dictate._copy('hello world'); recall._copy('hello world')"); T2=$(date +%s)
check "wl-copy: Copy returns at once although wl-copy leaves a background process (nothing of ours is held open, so a caller waiting on the output pipe is not stuck)" '(( T2 - T1 < 3 )) && [[ $(grep -c . "$W/wlcopy.log") == 2 ]] && [[ $(cat "$W/clip") == "hello world" ]]'
check "wl-copy: started with stdout/stderr on /dev/null (no captured pipes) and in its own process group (a closing window does not take it down)" 'grep -qx "out=/dev/null err=/dev/null own_group=yes" "$W/wlcopy.log"'
unset FAKE_WLCOPY_HOLD
echo "== live: the window goes away"
dfresh; mkdir -p "$W/gate"; export FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100 FAKE_PW_GATE=$W/gate
"$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & LP=$!
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'; touch "$W/gate/go2" "$W/gate/go3"; waitfor '[[ $(grep -cE "^$TS " "$DAILY") == 3 ]]'
steno live --toggle; waitfor '[[ $(grep -c "^clean:" "$DAILY") == 1 ]]'
check "live --toggle (Ctrl+backtick) while the popup records: recording stops and the clean pass runs (clean block written, no end line yet)" '[[ $(endn) == 0 ]] && grep -qE "^$TS Clean 15 seconds\.$" "$DAILY" && ! grep -q kitty "$W/kitty.log" 2>/dev/null'
kill -HUP $LP; wait $LP; echo $? > "$W/rc"
check "window closed at the choice step: end line ok · not copied (window closed); nothing copied or sent" '[[ ! -e $W/clip ]] && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · not copied \(window closed\)$"'
check "the instance's registry entry is gone afterwards" '[[ -z $(ls "$XDG_RUNTIME_DIR/stenographr/live" 2>/dev/null | grep json) ]]'
dfresh; mkdir -p "$W/gate"; export FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100 FAKE_PW_GATE=$W/gate
"$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & LP=$!
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'; touch "$W/gate/go2"; waitfor '[[ $(grep -cE "^$TS " "$DAILY") == 2 ]]'
kill -HUP $LP; wait $LP
check "window closed WHILE recording: stopped, clean block written for what was said, end line says no delivery" 'grep -q "^clean:" "$DAILY" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · not copied \(window closed\)$" && [[ ! -e $W/clip ]]'
dfresh; mkdir -p "$W/gate"; export FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_FAIL=1 FAKE_PW_GATE=$W/gate
"$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & LP=$!
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'; kill -HUP $LP; wait $LP
check "window closed and the clean pass can't run: live lines kept, the end line says why" 'grep -q "\] one" "$DAILY" && ! grep -q "^clean:" "$DAILY" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · FAILED: clean pass failed, see steno.log$" && grep -q "ERROR live clean pass failed" "$LOG"'
unset FAKE_ENGINE_CLEAN_FAIL
dfresh; mkdir -p "$W/gate"; export FAKE_ENGINE_TEXT="one|two|three" FAKE_PW_GATE=$W/gate
"$PY" -m stenographr.cli $LIVEARGS >/dev/null 2>&1 & LP=$!
waitfor 'grep -q "\] one" "$DAILY" 2>/dev/null'; touch "$W/gate/go2"; waitfor '[[ $(grep -cE "^$TS " "$DAILY") == 2 ]]'
kill -9 $LP; wait $LP 2>/dev/null; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null; sleep 0.3
check "killed (SIGKILL) mid-session: the start line has the audio pointer, the live lines so far are there, no end line" 'sed -n 1p "$DAILY" | grep -qE " · live · unknown · audio/[0-9-]+-live\.opus$" && [[ $(grep -cE "^$TS " "$DAILY") == 2 && $(endn) == 0 ]] && [[ -f $A/$(sed -n 1p "$DAILY" | grep -oE "audio/[^ ]+$") ]]'
steno recall </dev/null > "$W/rc.out" 2>&1
check "recall lists the killed session (from its live lines)" 'grep -qE "^1\. \[[0-9]{2}:[0-9]{2}\] live · one two$" "$W/rc.out"'
dfresh; unset FAKE_ENGINE_TEXT FAKE_ENGINE_CLEAN_TEXT FAKE_ENGINE_CLEAN_SECONDS
check "ydotool is never called (log absent) and the code no longer mentions it" '[[ ! -e $W/ydo.log ]] && ! grep -rqi ydotool "$PROJECT/src"'
check "type mode is gone: no toggle/_type-session subcommands" '! steno toggle >/dev/null 2>&1 && ! steno _type-session >/dev/null 2>&1'

echo "== notes mode"
# run `notes` in the background in directory $1; helpers wait for output / interrupt it
nstart() { local dir=$1; shift; mkdir -p "$dir"; ( cd "$dir" && exec env "$@" "$PY" -m stenographr.cli notes > "$W/notes.out" 2>"$W/notes.err" ) & NP=$!; }
nwait() { local n=$1 i; for i in $(seq 100); do [[ $(grep -c . "$W/notes.out") -ge $n ]] && return 0; sleep 0.05; done; return 1; }
nstop() { kill -INT $NP; wait $NP; echo $? > "$W/rc"; }
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

echo "== recall (pieces of one daily file)"
dfresh; mkdir -p "$A/clips"
TD=$(date +%F); YD=$(date -d yesterday +%F)
printf '# 20261109_083630 · recorded 2026-11-09 08:36 · 00:00:05\nsource: /x/20261109_083630.mp4\nengine: fake (cpu) · transcribed 2026-11-09 08:37\n\n[00:00:00 → 00:00:03 | 08:36:30] Hello there.\n[00:00:04 → 00:00:06 | 08:36:34] General Kenobi.\n' > "$A/clips/clip-2026-11-09-083630.txt"
LONG="Oh yeah, I didn't mean to blah blah blah blah blah blah blah blah blah blah blah blah blah"
{ for i in 1 2 3 4 5 6 7 8 9; do printf 'start: %s 10:0%s:00 · type · unknown\n[10:0%s:01] piece %s text\nend: %s 10:0%s:30 · 30s · ok\n' $TD $i $i $i $TD $i; done
  echo "clip: $TD 10:10:00 · 20261109_083630 → clips/clip-2026-11-09-083630.txt"
  printf 'start: %s 10:11:00 · notes · /tmp/p\n[10:11:01] first sentence.\n[10:11:07] second %s\n' $TD "sentence."          # crashed: no end line
  echo "other: $TD 10:12:00 · some-talk → other/$TD-some-talk.txt"                                                      # transcript file missing
  printf 'start: %s 10:13:00 · type · unknown\nend: %s 10:13:00 · 0s · FAILED: mic scarlett-mic not found, see steno.log\n' $TD $TD; } > "$A/steno-$TD.txt"
printf 'start: %s 09:00:00 · type · unknown\n[09:00:01] yesterday a\nend: %s 09:00:09 · 9s · ok\nstart: %s 09:30:00 · notes · /t\n[09:30:02] yesterday b %s\nend: %s 09:30:09 · 9s · ok\n' $YD $YD $YD "$LONG" $YD > "$A/steno-$YD.txt"
SUM=$(find "$A" -type f | sort | xargs cat | md5sum)
steno recall </dev/null > "$W/rc.out" 2>&1
check "header names the file and the piece count (the empty failed session is not a piece)" '[[ $(head -1 "$W/rc.out") == "steno-$TD.txt: 12 pieces" ]]'
check "default list: newest 10, newest first, numbered" '[[ $(grep -cE "^[0-9]+\. " "$W/rc.out") == 10 ]] && grep -qx "1. \[10:12\] other · some-talk · (no transcript)" "$W/rc.out" && grep -qx "2. \[10:11\] notes · first sentence. second sentence." "$W/rc.out" && grep -qx "10. \[10:03\] type · piece 3 text" "$W/rc.out" && ! grep -q "piece 2 text" "$W/rc.out"'
check "a clip piece: [HH:MM] clip · source · start of the transcript text (no header, no times)" 'grep -qx "3. \[10:10\] clip · 20261109_083630 · Hello there. General Kenobi." "$W/rc.out"'
check "prompt offers a = list all; no timestamps in any list line" 'grep -q "Which do you need to copy? (a = list all)" "$W/rc.out" && ! grep -qE "\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]" "$W/rc.out" && [[ ! -e $W/clip ]]'
printf 'a\n11\n' | steno recall > "$W/rc.out" 2>&1
check "a lists all 12 with the same numbering and asks again; 11 copies piece 11" '[[ $(grep -cE "^[0-9]+\. " "$W/rc.out") == 22 ]] && grep -qx "11. \[10:02\] type · piece 2 text" "$W/rc.out" && grep -qx "12. \[10:01\] type · piece 1 text" "$W/rc.out" && [[ $(grep -c "Which do you need" "$W/rc.out") == 2 ]] && [[ $(cat "$W/clip") == "piece 2 text" ]] && tail -1 "$W/rc.out" | grep -qx "piece 2 text"'
printf '3\n' | steno recall > "$W/rc.out" 2>&1
check "picking the clip piece copies the transcript text only: no header, no times" '[[ $(cat "$W/clip") == "Hello there. General Kenobi." ]] && tail -2 "$W/rc.out" | head -1 | grep -q "recalled:$" && tail -1 "$W/rc.out" | grep -qx "Hello there. General Kenobi."'
rm -f "$W/clip"; printf '1\n' | steno recall > "$W/rc.out" 2>&1; echo $? > "$W/rc"
check "missing transcript file: says so, copies nothing, exit 1" '[[ ! -e $W/clip && $(cat "$W/rc") == 1 ]] && grep -q "transcript file is missing: .*other/$TD-some-talk.txt" "$W/rc.out"'
printf '2\n' | steno recall >/dev/null 2>&1
check "a session piece copies its sentences joined by spaces, never timestamps" '[[ $(cat "$W/clip") == "first sentence. second sentence." ]]'
rm -f "$W/clip"; printf '\n' | steno recall >/dev/null 2>&1; printf 'q\n' | steno recall >/dev/null 2>&1; steno recall </dev/null >/dev/null 2>&1
check "Enter, q and EOF copy nothing" '[[ ! -e $W/clip ]]'
printf '99\nq\n' | steno recall > "$W/rc.out" 2>&1
check "an out-of-range number asks again instead of copying" 'grep -q "choose 1 to 12" "$W/rc.out" && [[ ! -e $W/clip ]]'
steno recall 11 </dev/null > "$W/rc.out" 2>&1
check "recall 11 copies piece 11 without listing" '[[ $(cat "$W/clip") == "piece 2 text" ]] && ! grep -q "Which do you need" "$W/rc.out" && [[ $(grep -c . "$W/rc.out") == 2 ]]'
rm -f "$W/clip"; steno recall 3 >/dev/null 2>&1; check "recall 3 = the clip piece" '[[ $(cat "$W/clip") == "Hello there. General Kenobi." ]]'
rm -f "$W/clip"; steno recall 13 >/dev/null 2>&1; echo $? > "$W/rc"; check "recall 13: error, nothing copied" '[[ $(cat "$W/rc") == 1 && ! -e $W/clip ]]'
check "recall never writes any file" '[[ $(find "$A" -type f | sort | xargs cat | md5sum) == "$SUM" ]]'
printf 'start: %s 10:13:00 · type · unknown\nend: %s 10:13:00 · 0s · FAILED: mic scarlett-mic not found, see steno.log\n' $TD $TD > "$A/steno-$TD.txt"
steno recall </dev/null > "$W/rc.out" 2>&1
check "today has no pieces: falls back to the latest day that does" '[[ $(head -1 "$W/rc.out") == "steno-$YD.txt: 2 pieces" ]] && grep -qE "^1\. \[09:30\] notes · yesterday b Oh yeah, I didn.t mean to blah.*\.\.\.$" "$W/rc.out" && grep -qx "2. \[09:00\] type · yesterday a" "$W/rc.out"'
printf 'start: %s 08:00:00 · type · unknown\n[08:00:01] old format\nend: %s 08:00:09 · 9s · ok\nstart: %s 08:10:00 · notes · /x/steno/steno-2026-11-09.txt · audio/2026-11-09-081000-notes.opus\n[08:10:02] new format notes\nend: %s 08:10:09 · 9s · ok\nstart: %s 08:20:00 · type · unknown · audio/2026-11-09-082000-type.opus\n[08:20:02] new format type\nstart: %s 08:30:00 · type · unknown · audio: none\n[08:30:02] no audio\nend: %s 08:30:09 · 9s · ok (audio FAILED, see steno.log)\n' $TD $TD $TD $TD $TD $TD $TD > "$A/steno-$TD.txt"
steno recall </dev/null > "$W/rc.out" 2>&1
check "recall reads old and new start-line formats (path + audio pointer, audio: none, no end line)" '[[ $(head -1 "$W/rc.out") == "steno-$TD.txt: 4 pieces" ]] && grep -qx "1. \[08:30\] type · no audio" "$W/rc.out" && grep -qx "2. \[08:20\] type · new format type" "$W/rc.out" && grep -qx "3. \[08:10\] notes · new format notes" "$W/rc.out" && grep -qx "4. \[08:00\] type · old format" "$W/rc.out"'
check "parser: the audio pointer is its own field, not part of 'where' (old format: empty)" '"$PY" - <<EOF
from stenographr.daily import parse_sessions
t = open("$A/steno-$TD.txt").read()
p = parse_sessions(t)
assert [x.audio for x in p] == ["", "audio/2026-11-09-081000-notes.opus", "audio/2026-11-09-082000-type.opus", "audio: none"], [x.audio for x in p]
assert p[1].where == "/x/steno/steno-2026-11-09.txt" and p[0].where == "unknown" and p[3].where == "unknown"
assert p[2].status is None and p[3].status.startswith("ok (audio FAILED")
EOF'
printf '3\n' | steno recall >/dev/null 2>&1; check "...and copies the text only (no path, no audio pointer)" '[[ $(cat "$W/clip") == "new format notes" ]]'
printf 'start: %s 07:00:00 · live · unknown · audio/x-live.opus\n[07:00:01] live bit one\n[07:00:05] live bit two\nclean:\n[07:00:01] The clean sentence, whole.\n[07:00:20] A second clean paragraph.\nend: %s 07:00:30 · 30s · ok · copied\nstart: %s 07:10:00 · live · unknown · audio/y-live.opus\n[07:10:01] only live phrases here\n[07:10:04] and here\n' $TD $TD $TD > "$A/steno-$TD.txt"
steno recall </dev/null > "$W/rc.out" 2>&1
check "recall: a live session with a clean block shows (and copies) the clean text, one without falls back to its live lines" 'grep -qx "2. \[07:00\] live · The clean sentence, whole. A second clean paragraph." "$W/rc.out" && grep -qx "1. \[07:10\] live · only live phrases here and here" "$W/rc.out" && ! grep -q "live bit" "$W/rc.out"'
printf '2\n' | steno recall >/dev/null 2>&1; check "...the clipboard gets the clean text, no timestamps, no 'clean:'" '[[ $(cat "$W/clip") == "The clean sentence, whole. A second clean paragraph." ]]'
check "parser: live and clean text are separate fields; a crashed live block has no status" '"$PY" - <<EOF
from stenographr.daily import parse_sessions
p = parse_sessions(open("$A/steno-$TD.txt").read())
assert p[0].live == "live bit one live bit two" and p[0].clean == "The clean sentence, whole. A second clean paragraph." and p[0].text == p[0].clean
assert p[0].status == "ok · copied" and p[1].clean == "" and p[1].text == p[1].live and p[1].status is None
EOF'
check "clean-pass chunking: merged up to ~30 s, split only at the longest pauses, nothing lost" '"$PY" - <<EOF
from stenographr.engines.parakeet import merge_spans
spans = [(0, 5), (5.5, 10), (12, 20), (20.4, 28), (31, 40), (40.2, 55), (60, 65)]
ch = merge_spans(spans, 30)
assert ch[0][0] == 0 and ch[-1][1] == 65, ch
assert all(b - a <= 30.5 for a, b in ch), ch                       # no chunk past the cap
assert ch[:2] == [(0, 28), (31, 65)] or ch[0] == (0, 28), ch        # the first cut is at the longest gap (28 -> 31)
assert merge_spans([(0, 3)], 30) == [(0, 3)] and merge_spans([], 30) == []
EOF'
rm -rf "$A"; mkdir -p "$A"; steno recall </dev/null >/dev/null 2>&1; echo $? > "$W/rc"; check "nothing to recall: exit 1" '[[ $(cat "$W/rc") == 1 ]]'

echo "== GNOME keybinding"
GS=$FAKE_GSETTINGS; MK=org.gnome.settings-daemon.plugins.media-keys; C0=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
rm -rf "$GS"; mkdir -p "$GS/$MK" "$GS/$MK.custom-keybinding:$C0"
echo "['$C0']" > "$GS/$MK/custom-keybindings"
echo "'Other'" > "$GS/$MK.custom-keybinding:$C0/name"; echo "'<Control><Alt>h'" > "$GS/$MK.custom-keybinding:$C0/binding"; echo "'kitty /x/other'" > "$GS/$MK.custom-keybinding:$C0/command"
BEFORE0=$(cat "$GS/$MK.custom-keybinding:$C0"/* | md5sum)
steno keybinding install >/dev/null; C1=${C0%custom0/}custom1/
check "list gets the new entry appended, the old one kept first" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"', '"'$C1'"']" ]]'
check "existing entry unchanged" '[[ $(cat "$GS/$MK.custom-keybinding:$C0"/* | md5sum) == "$BEFORE0" ]]'
check "new entry: name, <Control>grave, absolute path + live --toggle" '[[ $(cat "$GS/$MK.custom-keybinding:$C1/name") == "'"'stenographr dictation'"'" && $(cat "$GS/$MK.custom-keybinding:$C1/binding") == "'"'<Control>grave'"'" ]] && grep -qE "^.(/[^ ]+)/stenographr live --toggle.$" "$GS/$MK.custom-keybinding:$C1/command"'
steno keybinding install >/dev/null
check "install twice: still one entry of ours" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"', '"'$C1'"']" ]]'
steno keybinding remove >/dev/null
check "remove: only ours goes, the other stays untouched" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"']" && $(cat "$GS/$MK.custom-keybinding:$C0"/* | md5sum) == "$BEFORE0" && ! -e $GS/$MK.custom-keybinding:$C1/name ]]'
rm -rf "$GS"; steno keybinding install >/dev/null; check "no existing entries: becomes custom0" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"']" ]]'

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
