#!/usr/bin/env bash
# Section: live-gone. Run alone: tests/run-tests.sh live-gone
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
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
kill -9 $LP; wait $LP 2>/dev/null; pkill -f "$FB/pw-record" 2>/dev/null; sleep 0.3
check "killed (SIGKILL) mid-session: the start line has the audio pointer, the live lines so far are there, no end line" 'sed -n 1p "$DAILY" | grep -qE " · live · unknown · audio/[0-9-]+-live\.opus$" && [[ $(grep -cE "^$TS " "$DAILY") == 2 && $(endn) == 0 ]] && [[ -f $A/$(sed -n 1p "$DAILY" | grep -oE "audio/[^ ]+$") ]]'
steno recall </dev/null > "$W/rc.out" 2>&1
check "recall lists the killed session (from its live lines)" 'grep -qE "^1\. \[[0-9]{2}:[0-9]{2}\] live · one two$" "$W/rc.out"'
dfresh; unset FAKE_ENGINE_TEXT FAKE_ENGINE_CLEAN_TEXT FAKE_ENGINE_CLEAN_SECONDS
check "the code does not mention ydotool" '! grep -rqi ydotool "$PROJECT/src"'
check "type mode is gone: no toggle/_type-session subcommands" '! steno toggle >/dev/null 2>&1 && ! steno _type-session >/dev/null 2>&1'


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
