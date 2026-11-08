#!/usr/bin/env bash
# Offline tests: fake engine, fake nvidia-smi/ffmpeg/ffprobe first on PATH. No model, GPU, network or /data.
HERE=$(dirname "$(readlink -f "$0")"); PROJECT=$(dirname "$HERE")
W=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$W"' EXIT

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

echo "== .md format"
fresh; V=$(mkvid 20261108_063820.mp4)
FAKE_FF_SECONDS=12 FAKE_FF_DURATION=1515.647467 FAKE_ENGINE_SECONDS=5 steno clip "$V" --out "$OUT" --device cpu >/dev/null
M=$OUT/20261108_063820.md
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
check "archive copy identical"  'cmp -s "$M" "$A/clips/2026-11-08/20261108_063820.md"'

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
check "midnight crossing in file" 'grep -q "^\[00:00:05 → 00:00:10 | 00:00:03\]" "$OUT/20261108_235958.md" && grep -q "recorded 2026-11-08 23:59" "$OUT/20261108_235958.md"'

echo "== one transcript per source file"
fresh; V=$(mkvid 20261108_063820.mp4)
steno clip "$V" --out "$OUT" --device cpu >/dev/null
echo "x" >> "$OUT/20261108_063820.md"; BEFORE=$(cat "$OUT/20261108_063820.md")
steno clip "$V" --out "$OUT" --device cpu >"$W/o2" 2>"$W/e2"; echo $? > "$W/rc"
check "second run: exit 1, nothing new written" '[[ $(cat "$W/rc") == 1 && $(find "$OUT" "$A/clips" -type f | wc -l) == 2 && $(cat "$OUT/20261108_063820.md") == "$BEFORE" ]]'
check "refusal names both paths and the exact rm" 'grep -qxF "stenographr: 20261108_063820.mp4: already transcribed ($OUT/20261108_063820.md and $A/clips/2026-11-08/20261108_063820.md); to redo it: rm '"'$OUT/20261108_063820.md' '$A/clips/2026-11-08/20261108_063820.md'"'" "$W/e2"'
check "refusal logged, nothing on stdout" 'grep -q "WARN  20261108_063820.mp4 refused: already transcribed" "$LOG" && [[ ! -s $W/o2 ]]'
eval "$(grep -o "rm '.*'" "$W/e2")"
steno clip "$V" --out "$OUT" --device cpu >/dev/null; echo $? > "$W/rc"
check "after running the printed rm, it transcribes again" '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.md ]]'
fresh; mkdir -p "$W/sp"; : > "$W/sp/it's 20261108_063820.mp4"
steno clip "$W/sp/it's 20261108_063820.mp4" --out "$OUT" --device cpu >/dev/null; steno clip "$W/sp/it's 20261108_063820.mp4" --out "$OUT" --device cpu 2>"$W/e2" >/dev/null
check "rm line is shell-safe for odd names" 'grep -qF "rm '"'$OUT/it'\\\\''s 20261108_063820.md'"'" "$W/e2" && (. <(grep -o "rm .*" "$W/e2") && [[ ! -e "$OUT/it'"'"'s 20261108_063820.md" ]])'
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4); V3=$(mkvid 20261108_081500.mp4)
steno clip "$V2" --out "$OUT" --device cpu >/dev/null
steno clip "$V1" "$V2" "$V3" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "3 videos, 1 already done: other 2 written, exit 1" '[[ $(cat "$W/rc") == 1 && -f $OUT/20261108_063820.md && -f $OUT/20261108_081500.md && ! -e $OUT/20261108_070641-2.md ]]'
fresh; steno clip "$V1" --out "$OUT" --device cpu >/dev/null; rm "$OUT/20261108_063820.md"
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>"$W/e2"; echo $? > "$W/rc"
check "archive copy alone also triggers a refusal" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.md && $(find "$A/clips" -type f | wc -l) == 1 ]] && grep -q "already transcribed" "$W/e2" && grep -q "rm .*/2026-11-08/20261108_063820.md" "$W/e2"'
fresh; mkdir -p "$OUT"; echo precious > "$OUT/20261108_063820.md"
steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>&1
check "existing .md beside the video is untouched, no -2" '[[ $(cat "$OUT/20261108_063820.md") == precious && ! -e $OUT/20261108_063820-2.md && ! -e $A/clips ]]'
fresh; V1=$(mkvid 20261108_063820.mp4)
steno clip "$V1" >/dev/null
check "no --out: .md lands next to the video" '[[ -f $W/v/20261108_063820.md && -f $A/clips/2026-11-08/20261108_063820.md ]]'

echo "== archive layout and same-second names"
fresh; VA=$(mkvid 20250101_120000.mp4); VB=$(mkvid 20250101_120000_001.mp4)
steno clip "$VA" "$VB" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "same-second pair: both transcribed, exit 0" '[[ $(cat "$W/rc") == 0 && -f $OUT/20250101_120000.md && -f $OUT/20250101_120000_001.md ]]'
check "archive: <date>/<source stem>.md, distinct files" '[[ $(find "$A/clips" -type f | wc -l) == 2 ]] && head -1 "$A/clips/2025-01-01/20250101_120000.md" | grep -q "^# 20250101_120000 " && head -1 "$A/clips/2025-01-01/20250101_120000_001.md" | grep -q "^# 20250101_120000_001 "'
echo "== no audio stream"
fresh; VN=$(mkvid 20250102_080000.mp4)
FAKE_FF_NOAUDIO=1 steno clip "$VN" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "no audio: exit 0, .md has header and (no audio) only" '[[ $(cat "$W/rc") == 0 && $(sed -n 5,\$p "$OUT/20250102_080000.md") == "(no audio)" && $(head -1 "$OUT/20250102_080000.md") == "# 20250102_080000 · recorded 2025-01-02 08:00 · 00:25:15" ]]'
check "same placeholder in the archive, logged as INFO" 'cmp -s "$OUT/20250102_080000.md" "$A/clips/2025-01-02/20250102_080000.md" && grep -q "INFO  20250102_080000.mp4 finish: no audio" "$LOG"'
FAKE_FF_NOAUDIO=1 steno clip "$VN" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "second run refuses it" '[[ $(cat "$W/rc") == 1 ]] && grep -q "refused: already transcribed" "$LOG"'

echo "== model loaded once per run"
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4); V3=$(mkvid 20261108_081500.mp4)
export FAKE_ENGINE_COUNT=$W/count; : > "$FAKE_ENGINE_COUNT"
steno clip "$V1" "$V2" "$V3" --out "$OUT" --device cpu >/dev/null
check "3 videos: engine built once" '[[ $(grep -c . "$FAKE_ENGINE_COUNT") == 1 ]] && [[ $(grep -c "engine loaded" "$LOG") == 1 ]] && [[ $(grep -c "timing:" "$LOG") == 3 ]]'
fresh; : > "$FAKE_ENGINE_COUNT"
FAKE_ENGINE_FAIL_GPU=1 steno clip "$V1" "$V2" "$V3" --out "$OUT" >/dev/null; echo $? > "$W/rc"
check "GPU fails: all 3 done on CPU, one GPU attempt + one CPU engine" '[[ $(cat "$W/rc") == 0 && $(ls "$OUT" | wc -l) == 3 && $(grep -c . "$FAKE_ENGINE_COUNT") == 2 ]] && [[ $(grep -c "^cpu$" "$FAKE_ENGINE_COUNT") == 1 ]] && grep -q "(cpu) ·" "$OUT/20261108_081500.md"'
unset FAKE_ENGINE_COUNT

echo "== recording start fallback order"
fresh
V1=$(mkvid 20261108_063820_1.mp4); V2=$(mkvid camera-clip.mp4); V3=$(mkvid other.mp4)
steno clip "$V1" --out "$OUT" --recorded-at "2020-01-02 03:04" --device cpu >/dev/null
check "Samsung name (with suffix) beats --recorded-at" 'head -1 "$OUT/20261108_063820_1.md" | grep -q "recorded 2026-11-08 06:38 "'
steno clip "$V2" --out "$OUT" --recorded-at "2020-01-02 03:04" --device cpu >/dev/null
check "--recorded-at used when no timestamp in name"  'head -1 "$OUT/camera-clip.md" | grep -q "recorded 2020-01-02 03:04 " && grep -q "^\[00:00:00 → 00:00:05 | 03:04:00\]" "$OUT/camera-clip.md"'
"$PY" -c 'import os; os.utime("'"$V3"'", (1700000000, 1700000000))'
steno clip "$V3" --out "$OUT" --device cpu >/dev/null
EXP=$(date -d @1700000000 '+%Y-%m-%d %H:%M')
check "mtime when nothing else"                       'head -1 "$OUT/other.md" | grep -q "recorded $EXP "'
V4=$(mkvid 20269999_999999.mp4); steno clip "$V4" --out "$OUT" --recorded-at "2021-05-06 07:08:09" --device cpu >/dev/null
check "impossible Samsung date falls through"         'head -1 "$OUT/20269999_999999.md" | grep -q "recorded 2021-05-06 07:08 "'
steno clip "$V2" --out "$OUT" --recorded-at "garbage" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "bad --recorded-at is an error, not a guess"    '[[ $(cat "$W/rc") == 1 ]] && grep -q "ERROR.*cannot parse --recorded-at" "$LOG"'

echo "== .md -> .srt"
cat > "$W/t.md" <<'EOF'
# t · recorded 2026-11-08 06:38 · 01:00:00
source: /x/t.mp4
engine: fake (cpu) · transcribed 2026-11-08 10:00

[00:00:00 → 00:00:03 | 06:38:20] First line, with → arrow
[00:00:04 → 00:00:04 | 06:38:24] Zero length
[01:02:05 → 01:02:09 | 07:40:25] Over an hour
EOF
steno srt "$W/t.md" >/dev/null
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
steno srt "$W/t.md" >/dev/null
check "srt never overwrites"    '[[ -f $W/t-2.srt ]] && diff "$W/t.srt" "$W/t-2.srt" >/dev/null'
check "clip does not write srt" '[[ -z $(find "$OUT" "$A" -name "*.srt") ]]'

echo "== device selection"
fresh; V=$(mkvid 20261108_063820.mp4)
steno clip "$V" --out "$OUT" >/dev/null
check "free GPU -> gpu"          '[[ $(dev_of) == "device: gpu ("* ]] && grep -q "(gpu) ·" "$OUT/20261108_063820.md"'
fresh; FAKE_SMI="1000, 5" steno clip "$V" --out "$OUT" >/dev/null
check "not enough VRAM -> cpu"   '[[ $(dev_of) == "device: cpu (free VRAM 1000 MiB < needed 2500 MiB)" ]] && grep -q "(cpu) ·" "$OUT/20261108_063820.md"'
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
check "exit 0 and output written"  '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.md ]]'
check "md says cpu"                'grep -q "^engine: fake (cpu) ·" "$OUT/20261108_063820.md"'
check "failure logged as ERROR"    'grep -qE "ERROR 20261108_063820.mp4 GPU run failed, redoing on CPU: RuntimeError: fake CUDA failure" "$LOG"'

echo "== log"
fresh; steno clip "$V1" --out "$OUT" >/dev/null
check "lines: time level file message" '! grep -vE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (INFO |WARN |ERROR) [^ ]+ .+$" "$LOG"'
check "start, device, timing, finish"  'grep -q " start: " "$LOG" && grep -q " device: " "$LOG" && grep -q " timing: .*rtf=" "$LOG" && grep -q " finish: " "$LOG"'
fresh; FAKE_FF_FAIL=1 steno clip "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "ffmpeg failure: exit 1, logged with detail, no output" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.md ]] && grep -q "ERROR 20261108_063820.mp4 RuntimeError: ffmpeg failed (1): fake ffmpeg: Invalid data" "$LOG"'
fresh; steno clip "$W/v/missing.mp4" "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "missing file: error, next file still done" '[[ $(cat "$W/rc") == 1 && -f $OUT/20261108_063820.md ]] && grep -q "ERROR missing.mp4 FileNotFoundError" "$LOG"'

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
