# Extra helpers for the dictation sections (live, notes, recall, ...). Sourced after lib.sh.
export XDG_CONFIG_HOME=$W/xdg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # the user's global gitignore must not matter
export XDG_RUNTIME_DIR=$W/run FAKE_PW_LOG=$W/pw.log FAKE_CLIP=$W/clip FAKE_GSETTINGS=$W/gs
dfresh() { fresh; pkill -f "$FB/pw-record" 2>/dev/null; rm -rf "$XDG_RUNTIME_DIR" "$W/pw.log" "$W/clip" "$W/gate"; unset HB_CLAUDE_PANE TMUX_PANE FAKE_TMUX_SESSENV FAKE_TMUX_SESSION FAKE_MIC_MISSING FAKE_PW_FAIL FAKE_ENGINE_TEXT FAKE_ENGINE_SECONDS FAKE_PW_GATE FAKE_PW_CHUNKS FAKE_ENGINE_LOAD_DELAY FAKE_ENGINE_CLEAN_TEXT FAKE_ENGINE_CLEAN_SECONDS FAKE_ENGINE_CLEAN_FAIL FAKE_TMUX_CLIENTS FAKE_TMUX_PANES FAKE_TMUX_SEND_FAIL; rm -f "$W/tmux.log" "$W/kitty.log" "$W/wmctrl.log" "$W/wlcopy.log" "$W/sig"; unset FAKE_WLCOPY_HOLD; }
DAILY=$A/steno-$(date +%F).txt
BLK='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'

waitfor() { local i; for i in $(seq ${2:-120}); do eval "$1" && return 0; sleep 0.05; done; return 1; }
endn() { local n; n=$(grep -c '^end:' "$DAILY" 2>/dev/null); echo "${n:-0}"; }
plus() { date -d "$(date +%F) $1 $2 seconds" +%T; }            # plus HH:MM:SS N -> HH:MM:SS + N seconds
TS='\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]'

export FAKE_TMUX_LOG=$W/tmux.log FAKE_KITTY_LOG=$W/kitty.log FAKE_WMCTRL_LOG=$W/wmctrl.log FAKE_WLCOPY_LOG=$W/wlcopy.log
LIVEARGS="live --popup --headless --device cpu"
lpy() { "$PY" - "$@"; }                                   # python with the stenographr package + this test's env
LPRE='
import os, sys, time, threading, datetime as dt, asyncio
from stenographr.config import load
from stenographr.log import Log
from stenographr.live import LiveSession
cfg = load(); log = Log(cfg.archive / "steno.log"); W = os.environ["W"]
def wait(cond, secs=8):
    t = time.time()
    while time.time() - t < secs:
        if cond(): return
        time.sleep(0.05)
    raise SystemExit("timeout waiting for a condition")
def go(n): open(f"{W}/gate/go{n}", "w").close()
def start():
    s = LiveSession(cfg, log, "cpu"); s.phrases = []; s.on_phrase = s.phrases.append
    assert s.preflight() is None
    s.record_thread = threading.Thread(target=s.record); s.record_thread.start(); return s
def daily_text(): return open(sorted(__import__("glob").glob(str(cfg.archive / "steno-*.txt")))[-1]).read()
'
export W
CLEANENV="FAKE_ENGINE_TEXT=one|two|three FAKE_ENGINE_CLEAN_TEXT=Clean_{secs}_seconds. FAKE_ENGINE_CLEAN_SECONDS=100"
runcore() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds. Second sentence." FAKE_ENGINE_CLEAN_SECONDS=100; "$PY" -c "$LPRE
$1" ); }

REG=$XDG_RUNTIME_DIR/stenographr/live
fakeinst() {   # fakeinst NAME KIND RECORDING WHERE: a stand-in instance (counts the SIGUSR1s it gets), registered
  mkdir -p "$REG"; bash -c "trap 'echo got >> $W/sig.$1' USR1; while :; do sleep 0.05; done" stenographr live & FPID=$!
  printf '{"pid": %s, "kind": "%s", "where": "%s", "recording": %s, "started": 0}' "$FPID" "$2" "$4" "$3" > "$REG/$FPID.json"; sleep 0.15
}
UPRE='
from stenographr.live_ui import LiveApp, PickSession
async def until(pilot, cond, secs=8):
    t = time.time()
    while time.time() - t < secs:
        if cond(): return
        await pilot.pause(0.05)
    raise SystemExit("timeout")
async def click(pilot, sel):
    await pilot.pause(0.25)                       # let the button grid settle before clicking
    await pilot.click(sel)
def labels(app): return {b.id: (str(b.label), b.disabled, b.display) for b in app.screen.query("Button")}
def logtext(app): return [("".join(s.text for s in l)).strip() for l in app.query_one("RichLog").lines]
'
runui() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100; "$PY" -c "$LPRE$UPRE
$1" ); }
UPRE2='
def status(app): return str(app.query_one("#status").content)
def last(app): return str(app.query_one("#last").content)
def shown(app): return [b.id for b in app.screen.query("Button") if b.display]
'
runui2() { ( export FAKE_PW_GATE=$W/gate FAKE_ENGINE_TEXT="one|two|three" FAKE_ENGINE_CLEAN_TEXT="Clean {secs} seconds." FAKE_ENGINE_CLEAN_SECONDS=100 FAKE_ENGINE_COUNT=$W/count; "$PY" -c "$LPRE$UPRE$UPRE2
$1" ); }
# run `notes` in the background in directory $1; helpers wait for output / interrupt it
nstart() { local dir=$1; shift; mkdir -p "$dir"; ( cd "$dir" && exec env "$@" "$PY" -m stenographr.cli notes > "$W/notes.out" 2>"$W/notes.err" ) & NP=$!; }
nwait() { local n=$1 i; for i in $(seq 100); do [[ $(grep -c . "$W/notes.out") -ge $n ]] && return 0; sleep 0.05; done; return 1; }
nstop() { kill -INT $NP; wait $NP; echo $? > "$W/rc"; }
