#!/usr/bin/env bash
# Section: live-state. Run alone: tests/run-tests.sh live-state
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== live state machine (no screen, no recorder)"
dfresh
lpy <<'PY' > "$W/st.out" 2>&1
import itertools
from stenographr.live_state import LiveState, Phase, TRANSITIONS, IllegalTransition
from stenographr.live_flow import LiveFlow

def at(*path):                                     # a state that went through `path`
    s = LiveState()
    for p in path: s.go(p)
    return s

# 1. the table: every pair is either allowed (and works) or raises
bad = []
for a, b in itertools.product(Phase, Phase):
    s = LiveState(); s.phase = a
    try:
        s.go(b); ok = True
    except IllegalTransition:
        ok = False
    if ok != (b in TRANSITIONS[a]) or (ok and s.phase != b) or (not ok and s.phase != a): bad.append((a, b))
print("TABLE-BAD:", bad)
print("ERROR-IS-THE-END:", TRANSITIONS[Phase.ERROR] == frozenset())
# 2. the whole happy path of a loop, and of a popup, is in the table
at(Phase.READY, Phase.RECORDING, Phase.STOPPING, Phase.CLEANING, Phase.REVIEW, Phase.READY)
at(Phase.RECORDING, Phase.STOPPING, Phase.CLEANING, Phase.REVIEW, Phase.PICKING, Phase.REVIEW, Phase.ERROR)
print("PATHS: ok")
# 3. no skipping: Stop only from recording, cleaning only after a recording, review only after cleaning
print("NO-SKIP:", all(b not in TRANSITIONS[a] for a, b in [(Phase.READY, Phase.STOPPING), (Phase.READY, Phase.REVIEW),
      (Phase.RECORDING, Phase.REVIEW), (Phase.STOPPING, Phase.REVIEW), (Phase.CLEANING, Phase.READY)]))
# 4. the live text: partials are taken while recording AND stopping, not before or after
for ph, want in ((Phase.STARTING, False), (Phase.READY, False), (Phase.RECORDING, True), (Phase.STOPPING, True), (Phase.CLEANING, False), (Phase.REVIEW, False)):
    s = LiveState(); s.phase = ph
    took = s.set_partial("x")
    print(f"PARTIAL-{ph}:", "taken" if took and s.partial == "x" else "ignored" if not took and s.partial == "" else "WRONG", "want", "taken" if want else "ignored")
# 5. a finished line takes the stale partial (of the line it finished) away: never "one two two" on screen
s = at(Phase.RECORDING); s.add_phrase("one"); s.set_partial("two"); s.add_phrase("two")
print("STALE-PARTIAL:", s.lines, repr(s.partial))

# 6. the flow, with a fake screen: after Stop the last line and the cleared partial still reach the screen
from stenographr.config import load
from stenographr.log import Log
cfg = load(); log = Log(cfg.archive / "steno.log")
class View:
    def __init__(self): self.drawn = []
    def render_live(self, lines, partial): self.drawn.append((list(lines), partial))
view = View()
flow = LiveFlow(cfg, log, "cpu", True, view)
flow.state.go(Phase.RECORDING)
flow.add_phrase("one"); flow.set_partial("two")
flow.state.go(Phase.STOPPING)
flow.add_phrase("two"); flow.set_partial("")
print("STOPPING-DRAWN:", view.drawn[-2:], flow.phase)
flow.state.go(Phase.CLEANING)
n = len(view.drawn); flow.set_partial("late")
print("AFTER-STOP-IGNORED:", len(view.drawn) == n)
PY
check "table: every transition outside TRANSITIONS raises and leaves the phase alone, every one inside works; error is the end" 'grep -qx "TABLE-BAD: \[\]" "$W/st.out" && grep -qx "ERROR-IS-THE-END: True" "$W/st.out"'
check "the loop path and the popup path (incl. picking and error) are allowed; no phase can be skipped" 'grep -qx "PATHS: ok" "$W/st.out" && grep -qx "NO-SKIP: True" "$W/st.out"'
check "partial updates are taken while recording and stopping only" '[[ $(grep -c "^PARTIAL-.*: taken want taken$" "$W/st.out") == 2 && $(grep -c "^PARTIAL-.*: ignored want ignored$" "$W/st.out") == 4 ]]'
check "a finished line clears the stale partial (no duplicate line between the two updates)" 'grep -qx "STALE-PARTIAL: \[.one., .two.\] .." "$W/st.out"'
check "flow, stopping: the last line and the cleared partial both reach the screen; after stop a late partial does not" 'grep -qx "STOPPING-DRAWN: \[(\[.one., .two.\], ..), (\[.one., .two.\], ..)\] stopping" "$W/st.out" && grep -qx "AFTER-STOP-IGNORED: True" "$W/st.out"'
echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
