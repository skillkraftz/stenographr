#!/usr/bin/env bash
# Section: log. Run alone: tests/run-tests.sh log
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
V1=$(mkvid 20261108_063820.mp4)
echo "== log"
fresh; steno clip "$V1" --out "$OUT" >/dev/null
check "lines: time level file message" '! grep -vE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (INFO |WARN |ERROR) [^ ]+ .+$" "$LOG"'
check "start, device, timing, finish"  'grep -q " start: " "$LOG" && grep -q " device: " "$LOG" && grep -q " timing: .*rtf=" "$LOG" && grep -q " finish: " "$LOG"'
fresh; FAKE_FF_FAIL=1 steno clip "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "ffmpeg failure: exit 1, logged with detail, no output" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.txt ]] && grep -q "ERROR 20261108_063820.mp4 RuntimeError: ffmpeg failed (1): fake ffmpeg: Invalid data" "$LOG"'
fresh; steno clip "$W/v/missing.mp4" "$V1" --out "$OUT" >/dev/null 2>&1; echo $? > "$W/rc"
check "missing file: error, next file still done" '[[ $(cat "$W/rc") == 1 && -f $OUT/20261108_063820.txt ]] && grep -q "ERROR missing.mp4 FileNotFoundError" "$LOG"'


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
