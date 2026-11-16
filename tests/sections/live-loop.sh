#!/usr/bin/env bash
# Section: live-loop. Run alone: tests/run-tests.sh live-loop
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== live loop (pane / terminal instance)"
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
check "button step (loop): Copy, Append a, Send e, New, Close; project name on the bar" 'grep -q "^REVIEW: \[.copy., .append., .send., .new., .close.\] | Append a | Send e | alpha" "$W/ui.out"'
check "after Copy: back on Ready with 'Last: copied · HH:MM'; after Send: 'Last: sent to claude alpha · HH:MM'" 'grep -qE "^AFTER-COPY: Ready \| Last: copied · [0-9]{2}:[0-9]{2}$" "$W/ui.out" && grep -qE "^AFTER-SEND: Ready \| Last: sent to claude alpha · [0-9]{2}:[0-9]{2}$" "$W/ui.out" && grep -q "^EXITED" "$W/ui.out"'
check "two captures: two session blocks (end words copied / sent to claude alpha), two audio files, the typed text + one Enter, the clipboard has the clean text plus a space" '[[ $(grep -c "^start:" "$DAILY") == 2 && $(ls "$A/audio" | wc -l) == 2 ]] && grep -qE "· ok · copied$" "$DAILY" && grep -qE "· ok · sent to claude alpha$" "$DAILY" && [[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 && $(cat "$W/clip") == "Clean 15 seconds. " ]]'
check "the model was constructed ONCE for the whole app (two captures)" '[[ $(grep -c . "$W/count") == 1 ]] && [[ $(grep -c " live engine loaded" "$LOG") == 1 ]]'
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


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
