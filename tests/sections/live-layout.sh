#!/usr/bin/env bash
# Section: live-layout. Run alone: tests/run-tests.sh live-layout
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== live screen adapts to the terminal size (tall sidebar ... wide pane)"
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
def misfit(app, w, h):
    bad = []
    for b in app.screen.query("Button"):
        if not b.display: continue
        r = b.region
        if r.x < 0 or r.right > w or r.bottom > h or r.width < len(str(b.label)): bad.append((b.id, str(b.label), tuple(r)))
    br = app.screen.query_one("#banner_r")
    if str(br.content) and (br.region.right > w or br.region.width < len(str(br.content))): bad.append(("banner_r", tuple(br.region)))
    return bad
async def one(w, h):
    app = LiveApp(cfg, log, "cpu"); bad = []
    async with app.run_test(size=(w, h)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await pilot.pause(0.1); bad += misfit(app, w, h)
        go(2); go(3)
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3); await pilot.pause(0.1); bad += misfit(app, w, h)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.pause(0.2); bad += misfit(app, w, h)
        shown_n = len([b for b in app.screen.query("Button") if b.display])
        await pilot.press("q"); await pilot.pause(0.2)
    print(f"SIZE {w}x{h}: buttons at review={shown_n} misfits={bad}")
async def main():
    for w, h in ((28, 40), (36, 30), (60, 25), (80, 25), (120, 20)): await one(w, h)
asyncio.run(main())
' > "$W/ui.out" 2>&1
[[ -n $STENO_TEST_DEBUG ]] && cat "$W/ui.out"
for sz in 28x40 36x30 60x25 80x25 120x20; do
  check "terminal $sz: every visible button fits inside the screen with its whole label (ready, recording, button step); 5 buttons at the button step" 'grep -q "^SIZE '"$sz"': buttons at review=5 misfits=\[\]$" "$W/ui.out"'
done

echo "== live screen: one row of small buttons, the log gets the rest (STENO_SHOTS_DIR=dir also saves SVG pictures)"
dfresh; mkdir -p "$W/gate"; : > "$W/count"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
async def one(w, h):
    app = LiveApp(cfg, log, "cpu"); out = []
    shots = os.environ.get("STENO_SHOTS_DIR")
    async def look(phase):
        await pilot.pause(0.2)
        b = app.screen.query_one("#buttons"); lg = app.screen.query_one("#log")
        out.append(f"{phase}:bh={b.region.height}:bw={b.region.bottom}:lh={lg.region.height}:bt={min(x.region.height for x in app.screen.query("Button") if x.display)}")
        if shots: open(f"{shots}/live-{phase}-{w}x{h}.svg", "w").write(app.export_screenshot())
    async with app.run_test(size=(w, h)) as pilot:
        await until(pilot, lambda: app.phase == "ready"); await look("ready")
        go(2); go(3)
        await pilot.press("r"); await until(pilot, lambda: len(logtext(app)) == 3); await look("recording")
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await look("review")
        await pilot.press("q"); await pilot.pause(0.2)
    print(f"SHAPE {w}x{h}: " + " ".join(out))
async def main():
    for w, h in ((85, 12), (80, 24), (40, 30)): await one(w, h)
asyncio.run(main())
' > "$W/ui.out" 2>&1
[[ -n $STENO_TEST_DEBUG ]] && cat "$W/ui.out"
check "85x12: buttons one row (1 tall each), log gets the rest (>=5 rows)" 'grep -qE "^SHAPE 85x12: ready:bh=1:.*:lh=([5-9]|[1-9][0-9]):bt=1 recording:bh=1:.*:bt=1 review:bh=1:.*:lh=([5-9]|[1-9][0-9]):bt=1$" "$W/ui.out"'
check "80x24: all review buttons on one row; log gets >=18 rows" 'grep -qE "^SHAPE 80x24: ready:bh=1:.* recording:bh=1:.* review:bh=1:.*:lh=(1[89]|2[0-9]):bt=1$" "$W/ui.out"'
check "40x30: review buttons at most two rows, 1 tall each" 'grep -qE "^SHAPE 40x30: ready:bh=1:.* recording:bh=1:.* review:bh=2:.*:bt=1$" "$W/ui.out"'

echo "== live popup"
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "recording"); go(2); go(3)
        await until(pilot, lambda: os.path.exists(W + "/pw.log"))
        print("RECORDING:", app.phase, shown(app), "| mic opened:", os.path.exists(W + "/pw.log"))
        await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", shown(app), labels(app)["close"][0])
        await pilot.press("y"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "popup records immediately (no Ready screen), then Stop shows Copy, Claude append, Claude send, Close" 'grep -q "^RECORDING: recording \[.stop.\] | mic opened: True" "$W/ui.out" && grep -q "^REVIEW: \[.copy., .append., .send., .close.\] Close q" "$W/ui.out"'
check "popup exits after the choice (Copy): one block, end line copied" 'grep -q "^EXITED" "$W/ui.out" && [[ $(grep -c "^start:" "$DAILY") == 1 && $(cat "$W/clip") == "Clean 15 seconds. " ]] && tail -1 "$DAILY" | grep -qE "· ok · copied$"'
dfresh; mkdir -p "$W/gate"
runui2 '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: app.phase == "recording"); go(2); go(3); await until(pilot, lambda: len(logtext(app)) == 3)
        await pilot.press("s"); await until(pilot, lambda: app.phase == "review"); await pilot.press("escape"); await pilot.pause(0.4)
    print("EXITED")
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "popup Close (Esc): delivers nothing, end line closed, exits" 'grep -q "^EXITED" "$W/ui.out" && [[ ! -e $W/clip ]] && tail -1 "$DAILY" | grep -qE "· ok · closed$"'


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
