#!/usr/bin/env bash
# Section: srt. Run alone: tests/run-tests.sh srt
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
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


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
