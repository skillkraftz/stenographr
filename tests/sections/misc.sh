#!/usr/bin/env bash
# Section: misc. Run alone: tests/run-tests.sh misc
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== round 1: leaks, lost audio, device, daily file"
# 1. no .err files; what pw-record said goes to steno.log
dfresh; mkdir -p "$W/nf0"; (cd "$W/nf0" && FAKE_PW_FAIL=1 steno notes </dev/null >/dev/null 2>&1)
check "no *.err files in the state dir; pw-record's stderr is in steno.log" '[[ -z $(find "$XDG_RUNTIME_DIR" -name "*.err" 2>/dev/null) ]] && grep -q "WARN  notes pw-record said: fake pw-record: no such target" "$LOG"'
# 2. model fails to load after audio arrived: the audio still reaches the .opus; start line, FAILED end line, reason in steno.log
dfresh; mkdir -p "$W/nf"; export FAKE_FF_ENC_LOG=$W/enc2.log; rm -f "$FAKE_FF_ENC_LOG"
(cd "$W/nf" && FAKE_PW_CHUNKS=1 FAKE_ENGINE_LOAD_DELAY=1 FAKE_ENGINE_FAIL=1 steno notes </dev/null >/dev/null 2>&1); echo $? > "$W/rc"
check "model load fails: all audio recorded so far is in the .opus (1 x 5 s mono)" 'grep -qE "libopus .*\| 960000$" "$FAKE_FF_ENC_LOG" && [[ $(ls "$A/audio" | wc -l) == 1 ]]'
check "model load fails: exit 1, start line has the audio pointer, FAILED end line" '[[ $(cat "$W/rc") == 1 ]] && sed -n 1p "$DAILY" | grep -qE "^start: $BLK · notes · .* · audio/[0-9-]+-notes\.opus$" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · FAILED: engine failed, see steno.log$"'
check "model load fails: steno.log says why" 'grep -q "ERROR notes RuntimeError: fake model load failure" "$LOG"'
unset FAKE_FF_ENC_LOG
# 3. clip: the second of the two transcript files fails -> the first is removed, the source counts as failed, the rest goes on
fresh; mkdir -p "$A"; : > "$A/clips"                        # a FILE where the archive's clips/ folder should be
V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid camera-clip.mp4)
steno clip "$V1" "$V2" --out "$OUT" --device cpu >/dev/null 2>"$W/clip.err"; echo $? > "$W/rc"
DY=$A/steno-$(date +%F).txt
check "second write fails: exit 1, the first .txt is removed again, the other source is done" '[[ $(cat "$W/rc") == 1 && ! -e $OUT/20261108_063820.txt && -f $OUT/camera-clip.txt && -f $A/other/$(date -d @$(stat -c %Y "$V2") +%F)-camera-clip.txt ]]'
check "second write fails: logged, FAILED line (no pointer) for it, pointer for the other" 'grep -q "ERROR 20261108_063820.mp4 could not write .*clips/clip-2026-11-08-063820.txt.*removed .*20261108_063820.txt again" "$LOG" && grep -q "20261108_063820 · FAILED: see steno.log" "$DY" && ! grep -q "20261108_063820 →" "$DY" && grep -q "camera-clip → other/" "$DY"'
rm "$A/clips"; steno clip "$V1" --out "$OUT" --device cpu >/dev/null 2>&1; echo $? > "$W/rc"
check "after the cause is gone, the retry is not refused" '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.txt && -f $A/clips/clip-2026-11-08-063820.txt ]]'
# 4. every daily-file line is one write()
SW=$("$PY" -c '
import os, sys, datetime as dt, pathlib
from stenographr import daily
from stenographr.log import Log
calls = []; real = os.write
def w(fd, b): calls.append(len(b)); return real(fd, b)
os.write = w
p = pathlib.Path(sys.argv[1]); now = dt.datetime.now()
s = daily.Session(Log(p.with_name("l.log")), "t", [(p, None)], now, "live", "unknown", "audio/a.opus")
s.line("x " * 6000, now); s.end(now, "ok")
print(len(calls), p.read_text().count("\n"))' "$W/one-write.txt")
check "start, a very long line and end: one write() each (3 lines, 3 writes)" '[[ $SW == "3 3" ]]'
# 5. a clip pointer line inside an open live block does not break the block
PB=$("$PY" -c '
from stenographr.daily import parse_sessions
t = """start: 2026-11-11 10:00:00 · live · unknown · audio/a.opus
[10:00:01] hello there
clip: 2026-11-11 10:00:05 · 20261108_070641 → clips/clip-2026-11-08-070641.txt
[10:00:09] second phrase
end: 2026-11-11 10:00:12 · 12s · ok
clip: 2026-11-11 10:01:00 · x → clips/y.txt
"""
r = parse_sessions(t); print(len(r), r[0].text, r[0].status)')
check "recall parser: pointer line inside a block: one session, both phrases, its end line" '[[ $PB == "1 hello there second phrase ok" ]]'
# 6. the device is decided once per app / run
DD=$("$PY" -c '
import stenographr.runner as r
from stenographr.config import Config
calls = []; r.pick_device = lambda cfg, log, name, req: (calls.append(1), "gpu" if len(calls) == 1 else "cpu")[1]
e = r.Engines(Config(), None); print(e.decide("auto", "live"), e.decide("auto", "live"), len(calls))')
check "Engines.decide: first decision kept, decided once" '[[ $DD == "gpu gpu 1" ]]'
dfresh; mkconf ""; nstart "$W/nd1" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "notes, no config device: CPU even though the GPU is free" 'grep -q " notes device: cpu " "$LOG"'
dfresh; mkconf 'device = "gpu"'; nstart "$W/nd2" FAKE_PW_CHUNKS=1; nwait 1; nstop
check "notes, config device = gpu: still honoured" 'grep -q " notes device: gpu " "$LOG"'
dfresh; mkconf ""; steno clip "$(mkvid 20261108_063820.mp4)" --out "$OUT" >/dev/null 2>&1
check "clip keeps auto: GPU when it is free" 'grep -q "device: gpu (free VRAM" "$LOG"'
# 7. leftovers
check "no window_title; no type mode in the daily.py docstring" '! grep -rq --include=*.py window_title "$PROJECT/src" && ! grep -q " type " "$PROJECT/src/stenographr/daily.py"'
check "the fake engine is not registered without STENOGRAPHR_TESTING" '[[ $(env -u STENOGRAPHR_TESTING "$PY" -c "from stenographr.engines import FACTORIES; print(\"fake\" in FACTORIES)") == False ]]'

echo "== streaming preview (live only)"
dfresh; mkdir -p "$W/gate"; export FAKE_STREAM_COUNT=$W/scount; : > "$FAKE_STREAM_COUNT"
FAKE_ENGINE_SECONDS=2 FAKE_STREAM_STEP=4 FAKE_PW_CHUNKS=2 runcore '
s = LiveSession(cfg, log, "cpu"); s.phrases = []; s.partials = []; s.on_phrase = s.phrases.append; s.on_partial = s.partials.append
assert s.preflight() is None
s.record_thread = threading.Thread(target=s.record); s.record_thread.start()
wait(lambda: s.partials[-1:] == ["one"])
print("BEFORE:", s.phrases, "one" in daily_text().split("clean:")[0].replace("start:", ""), s.record_thread.is_alive())
go(2); wait(lambda: s.phrases == ["one"])
print("LINE-IN-DAILY-BEFORE-STOP:", [l for l in daily_text().splitlines() if l.endswith("] one")] != [])
s.request_stop(); s.record_thread.join(10); s.clean(); print("TEXT:", s.text())
print("PARTIALS:", s.partials)
' > "$W/core.out" 2>&1
check "words show before stop: the line in progress is reported (first word) while nothing is finished or filed yet" 'grep -q "^BEFORE: \[\] False True" "$W/core.out"'
check "a line is filed (daily, [HH:MM:SS] text) when it ends, still before stop; the partial is cleared after" 'grep -q "^LINE-IN-DAILY-BEFORE-STOP: True" "$W/core.out" && grep -q "^PARTIALS: \[.one., ..\]" "$W/core.out"'
check "the streaming model, not the per-phrase decode, made the lines (one 4 s line, not two 2 s ones); loaded once" 'grep -q "^BEFORE" "$W/core.out" && [[ $(grep -c "\] one$" "$DAILY") == 1 && $(grep -c "\] two$" "$DAILY") == 0 ]] && grep -q "INFO  live stream engine loaded" "$LOG" && [[ $(grep -c . "$FAKE_STREAM_COUNT") == 1 ]]'
check "at stop the clean pass runs as before and its text replaces the live text (clean: block, text())" 'grep -q "^TEXT: Clean 4 seconds. Second sentence." "$W/core.out" && grep -q "^clean:$" "$DAILY"'
dfresh; mkdir -p "$W/gate"
FAKE_STREAM_FAIL=1 FAKE_ENGINE_SECONDS=2 FAKE_PW_CHUNKS=2 runcore '
s = start(); go(2); wait(lambda: len(s.phrases) == 2); s.request_stop(); s.record_thread.join(10); print("PHRASES:", s.phrases)
' > "$W/core.out" 2>&1
check "no streaming model (fails to load): falls back to the per-phrase decode, logged, nothing lost" 'grep -q "^PHRASES: \[.one., .two.\]" "$W/core.out" && grep -q "ERROR live streaming preview model failed, using the per-phrase Parakeet decode" "$LOG"'
dfresh; mkdir -p "$W/gate"; : > "$FAKE_STREAM_COUNT"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
FAKE_ENGINE_SECONDS=2 FAKE_STREAM_STEP=4 FAKE_PW_CHUNKS=2 runui '
async def main():
    app = LiveApp(cfg, log, "cpu", popup=True)
    async with app.run_test(size=(80, 25)) as pilot:
        await until(pilot, lambda: logtext(app) == ["one"])
        print("PARTIAL:", logtext(app), app.phase, app._lines)
        go(2); await until(pilot, lambda: app._lines == ["one"] and app._partial_text == "")
        print("LINE:", logtext(app))
        await click(pilot, "#stop"); await until(pilot, lambda: app.phase == "review")
        print("REVIEW:", logtext(app))
        await pilot.press("q"); await pilot.pause(0.2)
asyncio.run(main())
' > "$W/ui.out" 2>&1
check "screen: the word appears while recording (before any line is finished), the line replaces it, the clean text replaces both at stop" 'grep -q "^PARTIAL: \[.one.\] recording \[\]" "$W/ui.out" && grep -q "^LINE: \[.one.\]" "$W/ui.out" && grep -q "^REVIEW: \[.Clean 4 seconds..\]" "$W/ui.out"'
check "the screen loaded the streaming model once (preload + capture share it)" '[[ $(grep -c . "$FAKE_STREAM_COUNT") == 1 ]]'
unset FAKE_STREAM_COUNT HB_CLAUDE_PANE FAKE_TMUX_PANES
dfresh; : > "$W/scount"; export FAKE_STREAM_COUNT=$W/scount; mkdir -p "$W/nn"
nstart "$W/nn" FAKE_PW_CHUNKS=1 FAKE_ENGINE_TEXT="again"; nwait 1; nstop
check "notes is unchanged: it never loads the streaming model, its lines come from the per-phrase decode" '[[ $(cat "$W/notes.out") == again ]] && [[ ! -s $W/scount ]] && ! grep -q "stream engine" "$LOG"'
unset FAKE_STREAM_COUNT

echo "== archive not writable"; dfresh
: > "$W/afile"; printf '[paths]\narchive = "%s/afile/sub"\n[engine]\nname = "fake"\n' "$W" > "$W/bad.toml"
mkdir -p "$W/an"; (cd "$W/an" && steno --config "$W/bad.toml" notes 2>"$W/err"); echo $? > "$W/rc"
check "notes, archive not writable: exit 1, names [paths] archive and the config file, no recording" '[[ $(cat "$W/rc") == 1 && ! -e $W/pw.log ]] && grep -q "archive folder .*/afile/sub is not writable" "$W/err" && grep -q "archive = .* under \[paths\] in .*config.toml" "$W/err"'
V=$(mkvid a.mp4); steno --config "$W/bad.toml" clip "$V" 2>"$W/err"; echo $? > "$W/rc"
check "clip, archive not writable: exit 1 with the same message, no transcript written" '[[ $(cat "$W/rc") == 1 && ! -e ${V%.mp4}.txt ]] && grep -q "is not writable" "$W/err"'
mkconf ""

echo "== scripts/get-models.sh"
M=$W/models-t; mkdir -p "$M/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8" "$M/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25"; : > "$M/silero_vad.onnx"
bash "$PROJECT/scripts/get-models.sh" "$M" </dev/null > "$W/gm.out" 2>&1; echo $? > "$W/rc"
check "get-models: everything present -> skips all, nothing to download, exit 0 (no network needed)" '[[ $(cat "$W/rc") == 0 ]] && [[ $(grep -c "^  have " "$W/gm.out") == 3 ]] && grep -q "nothing to download" "$W/gm.out"'
rmdir "$M/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25"
mkdir -p "$W/nocurl"; printf '#!/bin/sh\necho "fake curl: no network in tests" >&2; exit 6\n' > "$W/nocurl/curl"; chmod +x "$W/nocurl/curl"
PATH=$W/nocurl:$PATH bash "$PROJECT/scripts/get-models.sh" "$M" </dev/null > "$W/gm.out" 2>&1; echo $? > "$W/rc"
check "get-models: something missing and no terminal -> refuses to download without -y (exit 1, nothing downloaded)" '[[ $(cat "$W/rc") == 1 ]] && grep -q "missing  nemotron" "$W/gm.out" && grep -q "rerun with -y" "$W/gm.out" && [[ ! -e $M/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25 ]]'

echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
