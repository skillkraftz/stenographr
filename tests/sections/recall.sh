#!/usr/bin/env bash
# Section: recall. Run alone: tests/run-tests.sh recall
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
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
