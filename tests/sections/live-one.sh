#!/usr/bin/env bash
# Section: live-one. Run alone: tests/run-tests.sh live-one
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
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
check "Start while another instance records: the notice 'Recording in popup. Stop it and record here?' with Stop it / Cancel" 'grep -q "^NOTICE: Recording in popup. Stop it and record here? \[.stopit., .cancel.\] \[.Stop it y. *, .Cancel n.\]" "$W/ui.out"'
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
dfresh; rm -f "$W/xclip.log"; export FAKE_XCLIP_LOG=$W/xclip.log
T1=$(date +%s); FAKE_WLCOPY_HANG=1 "$PY" -c "from stenographr import clipboard; clipboard.copy('via xclip ')"; T2=$(date +%s)
check "wl-copy hangs (no Wayland focus): after ~3 s the text goes through xclip -selection clipboard" '[[ $(cat "$W/clip") == "via xclip " ]] && grep -qx -- "-selection clipboard" "$W/xclip.log" && (( T2 - T1 < 8 ))'
rm -f "$W/xclip.log"; "$PY" -c "from stenographr import clipboard; clipboard.copy('plain ')"
check "wl-copy works: xclip is not used" '[[ $(cat "$W/clip") == "plain " && ! -e $W/xclip.log ]]'
unset FAKE_XCLIP_LOG

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
