#!/usr/bin/env bash
# Section: live-core. Run alone: tests/run-tests.sh live-core
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== live --toggle (popups only) and the instance registry"
dfresh
steno live --toggle; echo $? > "$W/rc"
check "no popup open: kitty is launched once, 80x25 cells, titled, size not remembered, running 'stenographr live --popup'" '[[ $(cat "$W/rc") == 0 && $(grep -c . "$W/kitty.log") == 1 ]] && grep -qF -- "--title|stenographr live|" "$W/kitty.log" && grep -qF -- "-o|initial_window_width=80c|-o|initial_window_height=25c|-o|remember_window_size=no|" "$W/kitty.log" && grep -qE "\|-m\|stenographr.cli\|live\|--popup\|$" "$W/kitty.log"'
waitfor '[[ -s $W/wmctrl.log ]]'
check "the popup opens under XWayland (-o linux_display_server=x11) and gets marked always-on-top (-x -r by window class, -b add,above)" 'grep -qF -- "linux_display_server=x11" "$W/kitty.log" && grep -qxF -- "-x|-r|stenographr-live|-b|add,above|" "$W/wmctrl.log"'
steno live --toggle
check "pressed again before the popup has registered: no second window" '[[ $(grep -c . "$W/kitty.log") == 1 ]]'
dfresh; mkdir -p "$REG"; echo '{"pid": 999999, "kind": "popup", "where": "popup", "recording": true, "started": 0}' > "$REG/999999.json"
steno live --toggle
check "a stale registry entry (its process is gone) is ignored and removed: kitty is launched" '[[ $(grep -c . "$W/kitty.log") == 1 && ! -e $REG/999999.json ]]'
dfresh; rm -f "$W"/sig.*; fakeinst pop popup true popup; PP=$FPID
steno live --toggle; waitfor '[[ -s $W/sig.pop ]]'
check "a popup is recording: Ctrl+backtick stops it (SIGUSR1), no window opened" '[[ $(cat "$W/sig.pop") == got && ! -e $W/kitty.log ]]'
rm -f "$W/sig.pop"; printf '{"pid": %s, "kind": "popup", "where": "popup", "recording": false, "started": 0}' "$PP" > "$REG/$PP.json"
steno live --toggle; sleep 0.4
check "that popup is now at its button step: Ctrl+backtick raises it (-x -a, by window class), no stop signal, no new window" '[[ ! -e $W/sig.pop && ! -e $W/kitty.log ]] && grep -qxF -- "-x|-a|stenographr-live|" "$W/wmctrl.log"'
rm -f "$W/wmctrl.log"; printf '{"pid": %s, "kind": "popup", "where": "popup", "recording": true, "started": 0}' "$PP" > "$REG/$PP.json"
steno live --toggle; waitfor '[[ -s $W/sig.pop ]]'
check "the popup is recording again: Ctrl+backtick stops it and does not raise it" '[[ $(cat "$W/sig.pop") == got && ! -e $W/wmctrl.log ]]'
kill $PP 2>/dev/null; wait $PP 2>/dev/null
dfresh; rm -f "$W"/sig.*; fakeinst ready loop false alpha; L1=$FPID; fakeinst rec loop true beta; L2=$FPID
steno live --toggle; sleep 0.4
check "pane instances (one ready, one recording) are never touched: no signals; a popup is opened since none exists" '[[ ! -e $W/sig.ready && ! -e $W/sig.rec && $(grep -c . "$W/kitty.log") == 1 ]]'
kill $L1 $L2 2>/dev/null; wait $L1 $L2 2>/dev/null
dfresh; mkdir -p "$REG"; echo '{"pid": 999998, "kind": "loop", "where": "x", "recording": true, "started": 0}' > "$REG/999998.json"; fakeinst keep loop false x; K=$FPID
check "registry: stale entries are cleaned when read, live ones kept" '"$PY" - <<EOF
from stenographr import registry
ids = [i["pid"] for i in registry.instances()]
assert ids == [$K], ids
import os; assert not os.path.exists("$REG/999998.json")
EOF'
kill $K 2>/dev/null; wait $K 2>/dev/null

echo "== live session (core): live lines, clean pass, choices"
dfresh; mkdir -p "$W/gate"; export FAKE_FF_ENC_LOG=$W/enc.log; rm -f "$FAKE_FF_ENC_LOG"
runcore '
s = start()
wait(lambda: s.phrases == ["one"])
txt = daily_text()
assert "] one" in txt and "clean:" not in txt and "\nend:" not in txt, txt      # on screen AND in the daily file before stop
go(2); wait(lambda: len(s.phrases) == 2); go(3); wait(lambda: len(s.phrases) == 3)
s.request_stop(); s.record_thread.join(10); assert not s.record_thread.is_alive()
print("CLEAN:", s.clean())
print("STATUS:", s.deliver("copy"))
' > "$W/core.out" 2>&1
check "phrases are shown as recognised and already appended to the daily file (before the stop)" 'grep -q "^CLEAN:" "$W/core.out"'
check "the clean pass ran on the whole saved audio (15 s = 3 x 5 s at 16 kHz), not on the phrases" 'grep -qx "CLEAN: Clean 15 seconds. Second sentence." "$W/core.out"'
T0=$(sed -n 1p "$DAILY" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2} ·" | cut -d" " -f1)
check "daily block: start (live · unknown · audio), 3 timestamped live lines, clean: + timestamped clean lines, end ok · copied" '[[ $(sed -n 1p "$DAILY") =~ ^start:\ $BLK\ ·\ live\ ·\ unknown\ ·\ audio/[0-9-]+-live\.opus$ ]] && sed -n 2p "$DAILY" | grep -qx "\[$T0\] one" && sed -n 4p "$DAILY" | grep -qx "\[$(plus $T0 10)\] three" && sed -n 5p "$DAILY" | grep -qx "clean:" && sed -n 6p "$DAILY" | grep -qE "^$TS Clean 15 seconds\." && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · copied$"'
check "Copy: wl-copy got the clean text (no timestamps) plus ONE trailing space" '[[ $(cat "$W/clip") == "Clean 15 seconds. Second sentence. " ]]'
check "STATUS printed is the end line status" 'grep -qx "STATUS: ok · copied" "$W/core.out"'
ST=$(sed -n 1p "$DAILY" | grep -oE "^start: [0-9-]+ [0-9:]+" | cut -d" " -f2-); AF=$(date -d "$ST" +%Y-%m-%d-%H%M%S)-live.opus
check "audio: exactly one file named session start + mode (live), pointed to by the start line" '[[ $(ls "$A/audio" | wc -l) == 1 && -s $A/audio/$AF ]] && sed -n 1p "$DAILY" | grep -qE " · live · unknown · audio/$AF$"'
check "encoder was given mono 48 kHz Opus at 96 kbps and exactly the voice channel (3 x 5 s mono f32)" 'grep -qE "^-hide_banner .*-f f32le -ar 48000 -ac 1 -i - -c:a libopus -b:a 96k .* [^ ]+/audio/$AF \| 2880000$" "$W/enc.log"'

dfresh; mkdir -p "$W/gate"
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("new"))' > "$W/core.out" 2>&1
check "New: nothing is delivered, end line says new take" '[[ ! -e $W/clip ]] && ! grep -q "^send-keys" "$W/tmux.log" 2>/dev/null && grep -qx "STATUS: ok · new take" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · new take$"'
dfresh; mkdir -p "$W/gate"
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("close"))' > "$W/core.out" 2>&1
check "Close: nothing is delivered, end line says closed" '[[ ! -e $W/clip ]] && grep -qx "STATUS: ok · closed" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · closed$"'
dfresh; mkdir -p "$W/gate"
FAKE_MIC_MISSING=1 runcore 's = LiveSession(cfg, log, "cpu"); print("PRE:", s.preflight())' > "$W/core.out" 2>&1
check "mic missing: nothing recorded, daily block FAILED: mic scarlett-mic not found, no audio" 'grep -qx "PRE: mic scarlett-mic not found" "$W/core.out" && [[ ! -e $W/pw.log && ! -e $A/audio ]] && grep -qE "^start: $BLK · live · unknown$" "$DAILY" && grep -qE "^end: $BLK · [0-9]+s · FAILED: mic scarlett-mic not found, see steno.log$" "$DAILY"'
dfresh; mkdir -p "$W/gate"; export FAKE_FF_ENC_FAIL=1
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("copy"))' > "$W/core.out" 2>&1
check "encoder fails: the session still runs and delivers (clipboard set)" '[[ -s $W/clip ]] && grep -q "^STATUS:" "$W/core.out"'
check "encoder fails: start line says audio: none, end line says audio FAILED" 'sed -n 1p "$DAILY" | grep -qE "^start: $BLK · live · unknown · audio: none$" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok \(audio FAILED, see steno.log\) · copied$"'
check "encoder fails: logged with the reason; no audio file" 'grep -q "ERROR live audio not saved .*ffmpeg exited at start .*Permission denied" "$LOG" && [[ ! -e $A/audio || -z $(ls -A "$A/audio") ]]'
unset FAKE_FF_ENC_FAIL FAKE_FF_ENC_LOG

echo "== live: Send to Claude (tmux)"
export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore '
from stenographr import tmuxsend
default, pane, panes, note = tmuxsend.choose_target()
print("TARGET:", default, pane, sorted(panes), note)
s = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean()
print("STATUS:", s.deliver("send", default, pane))
' > "$W/core.out" 2>&1
check "HB_CLAUDE_PANE (old name) in our environment, pane exists: that pane is the target (its session), no picker" 'grep -qx "TARGET: alpha %0 \[.alpha., .beta.\] None" "$W/core.out"'
check "Send: the text on ONE line (no trailing space) in one send-keys -l call to alpha's pane (%0), then exactly one Enter key, in that order" '[[ $(grep -c "^send-keys|" "$W/tmux.log") == 2 ]] && [[ $(grep "^send-keys|" "$W/tmux.log" | sed -n 1p) == "send-keys|-t|%0|-l|--|Clean 15 seconds. Second sentence.|" && $(grep "^send-keys|" "$W/tmux.log" | sed -n 2p) == "send-keys|-t|%0|Enter|" ]]'
check "end line: sent to claude alpha; nothing on the clipboard" '[[ ! -e $W/clip ]] && grep -qx "STATUS: ok · sent to claude alpha" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · sent to claude alpha$"'
dfresh; mkdir -p "$W/gate"; export HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore 's = start(); wait(lambda: s.phrases == ["one"]); go(2); go(3); wait(lambda: len(s.phrases) == 3); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("append", "alpha"))' > "$W/core.out" 2>&1
check "Append: the text plus ONE trailing space in one send-keys -l call, and NO Enter" '[[ $(grep -c "^send-keys|" "$W/tmux.log") == 1 ]] && grep -qxF "send-keys|-t|%0|-l|--|Clean 15 seconds. Second sentence. |" "$W/tmux.log" && ! grep -qi "enter" "$W/tmux.log"'
check "end line: appended to claude alpha" 'grep -qx "STATUS: ok · appended to claude alpha" "$W/core.out" && tail -1 "$DAILY" | grep -qE "^end: $BLK · [0-9]+s · ok · appended to claude alpha$"'
dfresh; mkdir -p "$W/gate"; export FAKE_TMUX_SEND_FAIL=1 HB_CLAUDE_PANE=%0 FAKE_TMUX_PANES='alpha\t%0\tclaude'
runcore 's = start(); wait(lambda: s.phrases == ["one"]); s.request_stop(); s.record_thread.join(10); s.clean(); print("STATUS:", s.deliver("send", "alpha"))' > "$W/core.out" 2>&1
check "tmux send fails: end line FAILED: send to claude failed, logged" 'grep -qx "STATUS: FAILED: send to claude failed, see steno.log" "$W/core.out" && grep -q "ERROR live send to claude alpha failed" "$LOG"'
unset FAKE_TMUX_SEND_FAIL
dfresh; export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "nothing set (no pane variable): no target; the picker list holds the sessions that have a claude pane" 'grep -qx "TARGET: None None \[.alpha., .beta.\] None" "$W/core.out"'
export FAKE_TMUX_PANES='gamma\t%5\tbash\nbeta\t%2\tclaude'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "nothing set, one other session has a claude pane: the picker lists it" 'grep -qx "TARGET: None None \[.beta.\] None" "$W/core.out"'
export FAKE_TMUX_PANES='alpha\t%0\tbash'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "no claude pane anywhere: no target" 'grep -qx "TARGET: None None \[\] None" "$W/core.out"'
export FAKE_TMUX_PANES='alpha\t%0\tclaude\nbeta\t%2\tclaude'
export TMUX_PANE=%9 FAKE_TMUX_SESSION=beta FAKE_TMUX_SESSENV='HB_CLAUDE_PANE=%2'
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "only the session environment has it (our pane's session -> show-environment): same, pane %2, session beta, no picker" 'grep -qx "TARGET: beta %2 \[.alpha., .beta.\] None" "$W/core.out" && grep -q "^show-environment|-t|beta|HB_CLAUDE_PANE|" "$W/tmux.log"'
export HB_CLAUDE_PANE=%0
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "the environment variable wins over the session environment" 'grep -qx "TARGET: alpha %0 \[.alpha., .beta.\] None" "$W/core.out"'
export HB_CLAUDE_PANE=%77
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "stale id: the notice 'the Claude pane is gone', no target (picker)" 'grep -qx "TARGET: None None \[.alpha., .beta.\] the Claude pane is gone" "$W/core.out"'
export STENO_CLAUDE_PANE=%2
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "STENO_CLAUDE_PANE wins over the old HB_CLAUDE_PANE (even a stale one)" 'grep -qx "TARGET: beta %2 \[.alpha., .beta.\] None" "$W/core.out"'
unset HB_CLAUDE_PANE
runcore 'from stenographr import tmuxsend; d, pn, p, nt = tmuxsend.choose_target(); print("TARGET:", d, pn, sorted(p), nt)' > "$W/core.out" 2>&1
check "STENO_CLAUDE_PANE alone is enough" 'grep -qx "TARGET: beta %2 \[.alpha., .beta.\] None" "$W/core.out"'
unset STENO_CLAUDE_PANE TMUX_PANE FAKE_TMUX_SESSION FAKE_TMUX_SESSENV
unset HB_CLAUDE_PANE


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
