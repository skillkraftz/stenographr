#!/usr/bin/env bash
# Section: manifest. Run alone: tests/run-tests.sh manifest
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
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


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
