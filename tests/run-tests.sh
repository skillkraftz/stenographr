#!/usr/bin/env bash
# Offline tests: fake engine, fake nvidia-smi/ffmpeg/ffprobe first on PATH. No model, GPU, network or /data.
HERE=$(dirname "$(readlink -f "$0")"); PROJECT=$(dirname "$HERE")
W=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null; rm -rf "$W"' EXIT

# python with numpy: $STENO_PY, else the uv tool venv, else system python
PY=${STENO_PY:-}
[[ -z $PY && -x $(uv tool dir 2>/dev/null)/stenographr/bin/python ]] && PY=$(uv tool dir)/stenographr/bin/python
[[ -z $PY ]] && PY=python3
"$PY" -c 'import numpy' 2>/dev/null || { echo "need a python with numpy (set STENO_PY)"; exit 2; }

export PATH=$HERE/fakebin:$PATH PYTHONPATH=$PROJECT/src PYTHONDONTWRITEBYTECODE=1
export STENOGRAPHR_CONFIG=$W/config.toml FAKE_SMI_SEQ=
A=$W/archive; OUT=$W/out; LOG=$A/steno.log
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
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
dfresh() { fresh; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null; rm -rf "$XDG_RUNTIME_DIR" "$W/pw.log" "$W/ydo.log" "$W/clip" "$W/gate"; unset FAKE_MIC_MISSING FAKE_PW_FAIL FAKE_YDOTOOL_FAIL FAKE_ENGINE_TEXT FAKE_ENGINE_SECONDS FAKE_PW_GATE FAKE_PW_CHUNKS FAKE_ENGINE_LOAD_DELAY; }
DAILY=$A/steno-$(date +%F).txt
BLK='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'

waitfor() { local i; for i in $(seq ${2:-120}); do eval "$1" && return 0; sleep 0.05; done; return 1; }
ydo_n() { local n; n=$(grep -c . "$W/ydo.log" 2>/dev/null); echo "${n:-0}"; }
endn() { local n; n=$(grep -c '^end:' "$DAILY" 2>/dev/null); echo "${n:-0}"; }
plus() { date -d "$(date +%F) $1 $2 seconds" +%T; }            # plus HH:MM:SS N -> HH:MM:SS + N seconds
TS='\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]'
SESS() { cut -d' ' -f1 "$XDG_RUNTIME_DIR/stenographr/state"; }

echo "== toggle (type mode, live)"
dfresh; mkdir -p "$W/gate"
FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" steno toggle; echo $? > "$W/rc"
waitfor '[[ $(ydo_n) -ge 1 ]]'
check "press 1 returns at once; sentence 1 is typed before any stop signal" '[[ $(cat "$W/rc") == 0 && $(cat "$W/ydo.log") == "type --file - | one " ]]'
check "recorder: scarlett-mic, 16 kHz, 2 ch, f32, raw, to stdout" 'grep -qxE -- "--target scarlett-mic --rate 16000 --channels 2 --format f32 --raw -" "$W/pw.log"'
touch "$W/gate/go2"; waitfor '[[ $(ydo_n) -ge 2 ]]'; touch "$W/gate/go3"; waitfor '[[ $(ydo_n) -ge 3 ]]'
printf 'type --file - | one \ntype --file - | two \ntype --file - | three \n' > "$W/ydo.exp"
check "ydotool called 3 times as the sentences arrive, each sentence + one space" 'diff "$W/ydo.log" "$W/ydo.exp"'
check "before the stop: nothing on the clipboard, no end line, but all 3 sentences are in the daily file" '[[ ! -e $W/clip && $(endn) == 0 && $(grep -cE "^$TS " "$DAILY") == 3 ]]'
steno toggle; echo $? > "$W/rc"; waitfor '[[ $(endn) -ge 1 ]]'
check "press 2: exit 0; clipboard has all 3 joined, no timestamps" '[[ $(cat "$W/rc") == 0 && $(cat "$W/clip") == "one two three" ]]'
T0=$(sed -n 1p "$DAILY" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2} ·" | cut -d" " -f1)
check "daily block: start, 3 lines timestamped recording start + offset (0, 5, 10 s), end ok" '[[ $(wc -l < "$DAILY") == 5 ]] && grep -qE "^start: $BLK · type · unknown$" "$DAILY" && sed -n 2p "$DAILY" | grep -qx "\[$T0\] one" && sed -n 3p "$DAILY" | grep -qx "\[$(plus $T0 5)\] two" && sed -n 4p "$DAILY" | grep -qx "\[$(plus $T0 10)\] three" && sed -n 5p "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok$"'
check "session over: state cleared, still exactly 3 ydotool calls" '[[ ! -e $XDG_RUNTIME_DIR/stenographr/state && $(ydo_n) == 3 ]]'
check "steno.log: start, device, finish" 'grep -q " type start: " "$LOG" && grep -q " type device: " "$LOG" && grep -q " type finish: 3 sentences, ok" "$LOG"'

dfresh; export FAKE_ENGINE_LOAD_DELAY=1.5 FAKE_ENGINE_TEXT="one|two|three"
steno toggle; sleep 0.5
check "model still loading: nothing typed yet" '[[ ! -e $W/ydo.log ]]'
waitfor '[[ $(ydo_n) -ge 3 ]]' 200
check "audio that arrived while the model loaded is still transcribed (3 sentences typed)" '[[ $(ydo_n) == 3 ]]'
steno toggle; waitfor '[[ $(endn) -ge 1 ]]'; unset FAKE_ENGINE_LOAD_DELAY
dfresh; export FAKE_ENGINE_LOAD_DELAY=1.5 FAKE_ENGINE_TEXT="one|two|three"
steno toggle; sleep 0.3; steno toggle; waitfor '[[ $(endn) -ge 1 ]]' 200; unset FAKE_ENGINE_LOAD_DELAY
check "stopped before the model finished loading: nothing lost, all 3 sentences typed and copied" '[[ $(ydo_n) == 3 && $(cat "$W/clip") == "one two three" ]] && grep -qE "^end: $BLK · [0-9]+s · ok$" "$DAILY"'

dfresh; FAKE_MIC_MISSING=1 steno toggle; echo $? > "$W/rc"
check "mic missing: exit 1, recorder never started, no state" '[[ $(cat "$W/rc") == 1 && ! -e $W/pw.log && ! -e $XDG_RUNTIME_DIR/stenographr/state ]]'
check "mic missing: daily block FAILED: mic scarlett-mic not found" 'grep -qE "^start: $BLK · type · unknown$" "$DAILY" && grep -qE "^end: $BLK · [0-9]+s · FAILED: mic scarlett-mic not found, see steno.log$" "$DAILY"'
check "mic missing: logged, no other input tried" 'grep -q "ERROR type mic scarlett-mic not found" "$LOG"'

dfresh; mkdir -p "$W/gate"
FAKE_YDOTOOL_FAIL=1 FAKE_PW_GATE=$W/gate FAKE_PW_CHUNKS=2 FAKE_ENGINE_TEXT="one|two" steno toggle
waitfor '[[ $(ydo_n) -ge 1 ]]'; touch "$W/gate/go2"; waitfor '[[ $(ydo_n) -ge 2 ]]'; steno toggle; waitfor '[[ $(endn) -ge 1 ]]'
check "ydotool fails: the clipboard still gets the whole session" '[[ $(cat "$W/clip") == "one two" ]]'
check "ydotool fails: daily has both sentences and FAILED: typing failed" '[[ $(grep -cE "^$TS " "$DAILY") == 2 ]] && grep -qE "^end: $BLK · [0-9]+s · FAILED: typing failed, see steno.log$" "$DAILY" && grep -q "ERROR type typing (ydotool) failed" "$LOG"'

dfresh; export FAKE_ENGINE_TEXT=" "
steno toggle; sleep 0.8; steno toggle; waitfor '[[ $(endn) -ge 1 ]]'
check "no speech: nothing typed, clipboard untouched, end 'ok (no speech)'" '[[ ! -e $W/ydo.log && ! -e $W/clip ]] && grep -qE "^end: $BLK · [0-9]+s · ok \(no speech\)$" "$DAILY" && [[ $(wc -l < "$DAILY") == 2 ]]'

dfresh; export FAKE_PW_CHUNKS=1 FAKE_ENGINE_TEXT="hello"
mkdir -p "$XDG_RUNTIME_DIR/stenographr"; echo "999999 1700000000" > "$XDG_RUNTIME_DIR/stenographr/state"
steno toggle; echo $? > "$W/rc"; waitfor '[[ $(ydo_n) -ge 1 ]]'
check "stale session file: a new session starts and types" '[[ $(cat "$W/rc") == 0 && -s $W/pw.log && $(cat "$W/ydo.log") == "type --file - | hello " && $(SESS) != 999999 ]] && grep -q "WARN  type stale session state" "$LOG"'
steno toggle; waitfor '[[ $(endn) -ge 1 ]]'; check "...and the next press ends it normally" '[[ $(cat "$W/clip") == "hello" ]]'
dfresh; FAKE_PW_FAIL=1 steno toggle; echo $? > "$W/rc"; waitfor '[[ $(endn) -ge 1 ]]'
check "recorder dies at start: FAILED block, state cleared" '[[ $(cat "$W/rc") == 0 ]] && grep -q "FAILED: recorder exited, see steno.log" "$DAILY" && waitfor "[[ ! -e \$XDG_RUNTIME_DIR/stenographr/state ]]"'

dfresh; mkdir -p "$W/gate"
FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" steno toggle; waitfor '[[ $(ydo_n) -ge 1 ]]'; touch "$W/gate/go2"; waitfor '[[ $(ydo_n) -ge 2 ]]'
kill -9 "$(SESS)"; sleep 0.2; pkill -f "$HERE/fakebin/pw-record" 2>/dev/null
check "session killed mid-way: daily has the 2 sentences so far and no end line" '[[ $(grep -cE "^$TS " "$DAILY") == 2 && $(endn) == 0 ]] && grep -qE "^start: $BLK · type" "$DAILY"'
steno recall </dev/null > "$W/rc.out" 2>&1
check "recall still lists the crashed session" 'grep -q "^1 piece\|: 1 piece$" "$W/rc.out" && grep -qE "^1\. \[[0-9]{2}:[0-9]{2}\] type · one two$" "$W/rc.out"'

echo "== notes mode"
# run `notes` in the background in directory $1; helpers wait for output / interrupt it
nstart() { local dir=$1; shift; mkdir -p "$dir"; ( cd "$dir" && exec env "$@" "$PY" -m stenographr.cli notes > "$W/notes.out" 2>"$W/notes.err" ) & NP=$!; }
nwait() { local n=$1 i; for i in $(seq 100); do [[ $(grep -c . "$W/notes.out") -ge $n ]] && return 0; sleep 0.05; done; return 1; }
nstop() { kill -INT $NP; wait $NP; echo $? > "$W/rc"; }
dfresh; ND=$W/nt; rm -rf "$ND"; mkdir -p "$W/gate"
nstart "$ND" FAKE_PW_GATE="$W/gate" FAKE_ENGINE_TEXT="one|two|three"
nwait 1; NF=$ND/steno-$(date +%F).txt
check "sentence 1: printed bare, already in both files (timestamped)" '[[ $(cat "$W/notes.out") == one ]] && grep -qE "^$TS one$" "$NF" && grep -qE "^$TS one$" "$DAILY" && ! grep -q "^end:" "$NF"'
check "notes file starts with the header, once" '[[ $(head -1 "$NF") == "stenographr notes · $ND" ]] && sed -n 2p "$NF" | grep -qE "^start: $BLK · notes · $ND$" && [[ $(grep -c "^stenographr notes ·" "$NF") == 1 ]]'
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

echo "== notes in a git repo"
dfresh; RD=$W/repo; rm -rf "$RD"; mkdir -p "$RD/sub"; git init -q "$RD"
printf 'node_modules' > "$RD/.gitignore"                     # no trailing newline: must not glue onto it
nstart "$RD/sub" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "steno-*.txt appended to the repo root .gitignore (own line)" '[[ $(cat "$RD/.gitignore") == "$(printf "node_modules\nsteno-*.txt")" ]] && [[ ! -e $RD/sub/.gitignore ]]'
check "git now ignores the notes file; nothing staged or committed" '(cd "$RD" && git check-ignore -q sub/steno-test.txt && [[ -z $(git status --porcelain --untracked-files=all | grep steno) ]] && ! git rev-parse HEAD >/dev/null 2>&1)'
check "the addition is logged" 'grep -q "INFO  notes added steno-\*.txt to .*/repo/.gitignore" "$LOG"'
nstart "$RD/sub" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "second run: .gitignore not touched again" '[[ $(grep -c "steno-\*.txt" "$RD/.gitignore") == 1 ]]'
dfresh; RD2=$W/repo2; rm -rf "$RD2"; mkdir -p "$RD2"; git init -q "$RD2"; printf 'steno-*.txt\n' > "$RD2/.gitignore"
nstart "$RD2" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "already ignored: .gitignore left as is" '[[ $(cat "$RD2/.gitignore") == "steno-*.txt" ]]'

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
check "new entry: name, <Control>grave, absolute path + toggle" '[[ $(cat "$GS/$MK.custom-keybinding:$C1/name") == "'"'stenographr dictation'"'" && $(cat "$GS/$MK.custom-keybinding:$C1/binding") == "'"'<Control>grave'"'" ]] && grep -qE "^.(/[^ ]+)/stenographr toggle.$" "$GS/$MK.custom-keybinding:$C1/command"'
steno keybinding install >/dev/null
check "install twice: still one entry of ours" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"', '"'$C1'"']" ]]'
steno keybinding remove >/dev/null
check "remove: only ours goes, the other stays untouched" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"']" && $(cat "$GS/$MK.custom-keybinding:$C0"/* | md5sum) == "$BEFORE0" && ! -e $GS/$MK.custom-keybinding:$C1/name ]]'
rm -rf "$GS"; steno keybinding install >/dev/null; check "no existing entries: becomes custom0" '[[ $(cat "$GS/$MK/custom-keybindings") == "['"'$C0'"']" ]]'

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
