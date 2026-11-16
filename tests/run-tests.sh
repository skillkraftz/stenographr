#!/usr/bin/env bash
# Offline tests, one file per section in tests/sections/, run in parallel (each with its own temp dir and fakes;
# shared helpers in lib.sh and lib-dictation.sh). No model, GPU, network or /data.
#   tests/run-tests.sh            all sections in parallel; prints each result, lists the failed ones, exit 1 if any
#   tests/run-tests.sh live-ui    just that section (output live, e.g. to debug; STENO_TEST_DEBUG=1 for more)
#   tests/run-tests.sh a b        several sections
HERE=$(dirname "$(readlink -f "$0")")
export STENO_STRICT=1                     # an illegal live phase move raises in the tests (in real use it is only logged)
all=(); for f in "$HERE"/sections/*.sh; do all+=("$(basename "$f" .sh)"); done
want=("$@"); [[ ${#want[@]} == 0 ]] && want=("${all[@]}")
for s in "${want[@]}"; do [[ -f $HERE/sections/$s.sh ]] || { echo "no section '$s'; sections: ${all[*]}"; exit 2; }; done

if [[ ${#want[@]} == 1 ]]; then exec bash "$HERE/sections/${want[0]}.sh"; fi

# make the uv .venv once here, so parallel sections don't race to create it (lib.sh does it when it is missing)
( . "$HERE/lib.sh" ) >/dev/null 2>&1 </dev/null || true

OUTD=$(mktemp -d); trap 'rm -rf "$OUTD"' EXIT
t0=$SECONDS
for s in "${want[@]}"; do
  ( s0=$SECONDS; bash "$HERE/sections/$s.sh" > "$OUTD/$s.out" 2>&1; echo $? > "$OUTD/$s.rc"; echo $((SECONDS-s0)) > "$OUTD/$s.t" ) &
done
wait
failed=(); pass=0; fail=0
for s in "${want[@]}"; do
  rc=$(cat "$OUTD/$s.rc"); line=$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$OUTD/$s.out" | tail -1)
  [[ -n $line ]] && { pass=$((pass + ${line%% passed*})); l=${line#*, }; fail=$((fail + ${l%% failed*})); }
  if [[ $rc == 0 ]]; then echo "ok   $s  (${line:-?}, $(cat "$OUTD/$s.t") s)"
  else echo "FAIL $s  (${line:-no result line, exit $rc}, $(cat "$OUTD/$s.t") s)"; failed+=("$s"); fi
done
for s in "${failed[@]}"; do echo; echo "----- $s"; grep -v '^  ok ' "$OUTD/$s.out" | tail -40; done
echo; echo "$pass passed, $fail failed in $((SECONDS-t0)) s"
if [[ ${#failed[@]} -gt 0 ]]; then echo "failed sections: ${failed[*]}  (rerun one: tests/run-tests.sh <section>)"; exit 1; fi
