#!/usr/bin/env bash
# Section: live-ui. Run alone: tests/run-tests.sh live-ui
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== live screen (Textual, headless pilot)"
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"])
        print("BANNER:", app.screen.query_one("#banner_l").content)
        print("RECORDING:", logtext(app), {k: v[2] for k, v in labels(app).items()})
        go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop")
        await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", logtext(app), labels(app))
        print("BANNER-R:", app.screen.query_one("#banner_r").content)
        await click(pilot, "#send")
        await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "screen: banner text, each phrase shown as recognised, only Stop visible while recording" 'grep -q "^BANNER: Live preview · final text is cleaned up when you stop" "$W/ui.out" && grep -q "^RECORDING: \[.one.\] {.start.: False, .stop.: True, .copy.: False, .append.: False, .send.: False, .new.: False, .close.: False, .stopit.: False, .cancel.: False}" "$W/ui.out"'
check "popup, after Stop: the clean text and exactly Copy, Append a, Send e, Close (no New); the project name is at the right end of the bar" 'grep -q "^REVIEW: \[.Clean 15 seconds..\]" "$W/ui.out" && grep -q ".append.: (.Append a., False, True)" "$W/ui.out" && grep -q ".send.: (.Send e., False, True)" "$W/ui.out" && grep -qF "Close q" "$W/ui.out" && grep -q ".new.: (.New r., False, False)" "$W/ui.out" && grep -qx "BANNER-R: alpha" "$W/ui.out"'
check "clicking Claude send: the text typed to %0, then one Enter; the window exits; end line sent to claude alpha" 'grep -q "^EXITED" "$W/ui.out" && [[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 ]] && grep -qxF "send-keys|-t|%0|-l|--|Clean 15 seconds.|" "$W/tmux.log" && grep -qxF "send-keys|-t|%0|Enter|" "$W/tmux.log" && tail -1 "$DAILY" | grep -qE "· ok · sent to claude alpha$"'
dfresh; mkdir -p "$W/gate"
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"])
        app._set_partial("two")                   # the last words heard, still in progress
        app.flow.state.go(Phase.STOPPING)         # Stop pressed: the loop flushes the last line, then clears the partial
        app._add_phrase("two")                    # flush(): that line is now finished
        app._set_partial("")                      # ... and the partial is cleared
        await until(pilot, lambda: len(logtext(app)) >= 2); await pilot.pause(0.2)
        print("STOPPING:", sorted(logtext(app)))   # sorted: under load the live feed can interleave
        app._set_partial("three"); app._add_phrase("three")    # a line finishes before the next partial update arrives:
        await pilot.pause(0.2); print("NO-DUP:", sorted(logtext(app)))   # the old partial must not show as a second "three"
        app.exit()
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "screen: the last line is shown once while stopping (the cleared partial is not dropped)" 'grep -q "^STOPPING: \[.one., .two.\]$" "$W/ui.out"'
check "screen: a finished line replaces the partial it was (between the two updates no line shows twice)" 'grep -q "^NO-DUP: \[.one., .three., .two.\]$" "$W/ui.out"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_PANES='alpha\t%0\tbash'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        print("CLAUDE:", labels(app)["append"], labels(app)["send"])
        await pilot.press("a"); await pilot.press("e"); await pilot.pause(0.2); print("PHASE-AFTER-AE:", app.phase)
        await pilot.press("y"); await pilot.pause(0.3)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "no claude pane: both Claude buttons are disabled (and their keys do nothing)" 'grep -q "^CLAUDE: (.Append a., True, True) (.Send e., True, True)" "$W/ui.out" && grep -q "^PHASE-AFTER-AE: review" "$W/ui.out" && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null'
check "the keys work too: s stops, y copies the clean text" 'grep -q "^EXITED" "$W/ui.out" && [[ $(cat "$W/clip") == "Clean 15 seconds. " ]] && tail -1 "$DAILY" | grep -qE "· ok · copied$"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("CLAUDE:", labels(app)["append"][0])
        await click(pilot, "#append"); await pilot.pause(0.3)
        print("PICKER:", type(app.screen).__name__, [str(o.prompt) for o in app.screen.query_one("OptionList").options])
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "ambiguous (two clients): Claude append opens a list of sessions with a claude pane; picking beta appends there (text + space, no Enter)" 'grep -q "^CLAUDE: Append a" "$W/ui.out" && grep -q "^PICKER: PickSession \[.alpha., .beta.\]" "$W/ui.out" && grep -q "^EXITED" "$W/ui.out" && grep -qxF "send-keys|-t|%2|-l|--|Clean 15 seconds. |" "$W/tmux.log" && ! grep -qi "enter" "$W/tmux.log" && tail -1 "$DAILY" | grep -qE "· ok · appended to claude beta$"'

dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%77 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"]); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("STATUS:", app.screen.query_one("#status").content)
        await click(pilot, "#append"); await pilot.pause(0.3)
        print("PICKER:", type(app.screen).__name__)
        await pilot.press("escape"); await pilot.pause(0.2)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "UI, stale id: status shows the Claude pane is gone, Append opens the picker" 'grep -q "^STATUS: .*the Claude pane is gone" "$W/ui.out" && grep -q "^PICKER: PickSession" "$W/ui.out"'
unset HB_CLAUDE_PANE


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
