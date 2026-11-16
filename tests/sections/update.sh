#!/usr/bin/env bash
# Section: update. Run alone: tests/run-tests.sh update
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
. "$HERE/lib-dictation.sh"
echo "== update"
UD=$W/upd; mkdir -p "$UD"; export FAKE_GIT_LOG=$UD/git.log FAKE_UV_LOG=$UD/uv.log
supd() { rm -f "$FAKE_GIT_LOG" "$FAKE_UV_LOG"; (cd / && PATH=$HERE/fakeupd:$PATH "$PY" -m stenographr.cli update) > "$UD/out" 2>&1; echo $? > "$W/rc"; }
dfresh; supd
check "up to date: shows source, branch, commit, 0 behind; ends with 'up to date at abc1234'; no pull, no uv; works from /" '[[ $(cat "$W/rc") == 0 ]] && grep -q "^source:  $PROJECT$" "$UD/out" && grep -q "^branch:  main$" "$UD/out" && grep -q "^commit:  abc1234 Fake subject$" "$UD/out" && grep -q "0 ahead, 0 behind" "$UD/out" && grep -qx "up to date at abc1234" "$UD/out" && grep -q "git fetch" "$FAKE_GIT_LOG" && ! grep -q "git pull" "$FAKE_GIT_LOG" && [[ ! -e $FAKE_UV_LOG ]]'
FAKE_GIT_BEHIND=2 supd
check "behind: pulls with --ff-only, lists the pulled commits, no uv, says restart" '[[ $(cat "$W/rc") == 0 ]] && grep -q "git pull --ff-only" "$FAKE_GIT_LOG" && grep -q "0 ahead, 2 behind" "$UD/out" && grep -q "pulled 2 commit" "$UD/out" && grep -q "ccc3333 first pulled commit" "$UD/out" && grep -q "^updated to abc1234" "$UD/out" && [[ ! -e $FAKE_UV_LOG ]]'
FAKE_GIT_BEHIND=1 FAKE_GIT_PYPROJECT=1 supd
check "pyproject.toml changed: uv tool install --editable .[gpu] --force from the checkout" '[[ $(cat "$W/rc") == 0 ]] && grep -qx "tool install --editable .\[gpu\] --force | $PROJECT" "$FAKE_UV_LOG"'
FAKE_GIT_BRANCH=feat/x FAKE_GIT_BEHIND=3 supd
check "wrong branch: says so, exit 1, nothing pulled or switched" '[[ $(cat "$W/rc") == 1 ]] && grep -q "not main" "$UD/out" && ! grep -qE "git (pull|checkout|switch|stash|reset)" "$FAKE_GIT_LOG" && [[ ! -e $FAKE_UV_LOG ]]'
FAKE_GIT_DIRTY=1 FAKE_GIT_BEHIND=3 supd
check "dirty tree: says so and lists the files, exit 1, nothing pulled" '[[ $(cat "$W/rc") == 1 ]] && grep -q "uncommitted changes" "$UD/out" && grep -q "M src/stenographr/cli.py" "$UD/out" && ! grep -qE "git (pull|checkout|switch|stash|reset)" "$FAKE_GIT_LOG"'
FAKE_GIT_FETCH_FAIL=1 supd
check "fetch fails: exit 1, nothing pulled" '[[ $(cat "$W/rc") == 1 ]] && grep -q "git fetch failed" "$UD/out" && ! grep -q "git pull" "$FAKE_GIT_LOG"'
dfresh; mkdir -p "$XDG_RUNTIME_DIR/stenographr/live"
bash -c 'sleep 20; :' stenographr live & LV=$!                  # a process whose command line looks like `stenographr live`
printf '{"pid": %s, "kind": "loop", "where": "tmux pane work:1.0", "recording": false, "started": 0}' $LV > "$XDG_RUNTIME_DIR/stenographr/live/$LV.json"
FAKE_GIT_BEHIND=1 supd
check "running live instances are listed (pid, kind, where) with a restart hint, and left running" 'grep -q "restart them" "$UD/out" && grep -q "pid $LV  loop  tmux pane work:1.0" "$UD/out" && [[ -d /proc/$LV ]]'
supd
check "up to date: instances are listed without the restart hint" 'grep -q "^running live instances:$" "$UD/out" && ! grep -q "restart them" "$UD/out"'
unset FAKE_GIT_LOG FAKE_UV_LOG

echo "== version"
check "--version prints the name and a version" '[[ $(steno --version) =~ ^stenographr\ [^\ ]+$ ]]'


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
