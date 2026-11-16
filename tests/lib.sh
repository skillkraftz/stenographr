# Shared by every section: temp dir ($W), fakes first on PATH, ok/bad/check, fresh, mkconf, steno. Sourced, never run.
# Offline tests: fake engine and fake CLIs (tests/fakebin) first on PATH. No model, GPU, network or /data.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")"); PROJECT=$(dirname "$HERE")
W=$(mktemp -d); FB=$W/fakebin; ln -s "$HERE/fakebin" "$FB"; trap 'jobs -p | xargs -r kill 2>/dev/null; pkill -f "$FB/pw-record" 2>/dev/null; rm -rf "$W"' EXIT

# python with numpy and textual: $STENO_PY, else the uv tool venv, else system python, else a uv .venv (below)
PY=${STENO_PY:-}
[[ -z $PY && -x $(uv tool dir 2>/dev/null)/stenographr/bin/python ]] && PY=$(uv tool dir)/stenographr/bin/python
[[ -z $PY ]] && PY=python3
# no python with the deps (e.g. the lab): make $PROJECT/.venv once with uv (gitignored, kept between runs)
if ! "$PY" -c 'import numpy, textual' 2>/dev/null && command -v uv >/dev/null; then
  [[ -x $PROJECT/.venv/bin/python ]] || uv venv -q "$PROJECT/.venv"
  uv pip install -q -p "$PROJECT/.venv/bin/python" numpy textual && PY=$PROJECT/.venv/bin/python
fi
"$PY" -c 'import numpy, textual' 2>/dev/null || { echo "need a python with numpy and textual (set STENO_PY)"; exit 2; }

export PATH=$FB:$PATH PYTHONPATH=$PROJECT/src PYTHONDONTWRITEBYTECODE=1
export STENOGRAPHR_TESTING=1 STENOGRAPHR_CONFIG=$W/config.toml FAKE_SMI_SEQ=
A=$W/archive; OUT=$W/out; LOG=$A/steno.log
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; [[ -n $STENO_TEST_DEBUG ]] && { echo "--- daily:"; cat "$DAILY" 2>/dev/null | cut -c1-120; echo "--- ui.out:"; tail -12 "$W/ui.out" 2>/dev/null | cut -c1-200; echo "--- log tail:"; tail -8 "$LOG" 2>/dev/null | cut -c1-150; echo "---"; }; fi; }
mkconf() { printf '[paths]\narchive = "%s"\nmodels = "%s/models"\n[engine]\nname = "fake"\n[device]\nvram_need_mib = 2000\nvram_margin_mib = 500\nmax_gpu_util_pct = 30\nbusy_processes = ["steno-test-busy"]\n%s\n' "$A" "$W" "$1" > "$W/config.toml"; }
steno() { "$PY" -m stenographr.cli "$@"; }
fresh() { rm -rf "$A" "$OUT"; : > "$W/rc"; unset FAKE_SMI FAKE_SMI_FAIL FAKE_ENGINE_FAIL_GPU FAKE_ENGINE_GPU FAKE_FF_FAIL FAKE_FF_NOAUDIO; export FAKE_SMI_SEQ=; }
mkconf ""
mkvid() { mkdir -p "$W/v"; : > "$W/v/$1"; echo "$W/v/$1"; }   # contents don't matter: ffmpeg/ffprobe are fakes
dev_of() { grep -o 'device: [a-z]* (.*)' "$LOG" | head -n${1:-1} | tail -n1; }
