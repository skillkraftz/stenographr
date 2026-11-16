#!/usr/bin/env bash
# Section: clip. Run alone: tests/run-tests.sh clip
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
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


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
