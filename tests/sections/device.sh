#!/usr/bin/env bash
# Section: device. Run alone: tests/run-tests.sh device
. "$(dirname "$(readlink -f "$0")")/../lib.sh"
echo "== device selection"
fresh; V=$(mkvid 20261108_063820.mp4)
steno clip "$V" --out "$OUT" >/dev/null
check "free GPU -> gpu"          '[[ $(dev_of) == "device: gpu ("* ]] && grep -q "(gpu) ·" "$OUT/20261108_063820.txt"'
fresh; FAKE_SMI="1000, 5" steno clip "$V" --out "$OUT" >/dev/null
check "not enough VRAM -> cpu"   '[[ $(dev_of) == "device: cpu (free VRAM 1000 MiB < needed 2500 MiB)" ]] && grep -q "(cpu) ·" "$OUT/20261108_063820.txt"'
fresh; FAKE_SMI="3500, 80" steno clip "$V" --out "$OUT" >/dev/null
check "busy GPU util -> cpu"     '[[ $(dev_of) == "device: cpu (GPU busy: utilization 80%"* ]]'
fresh; FAKE_SMI="2500, 29" steno clip "$V" --out "$OUT" >/dev/null
check "boundaries: VRAM == need+margin and util just under -> gpu" '[[ $(dev_of) == "device: gpu ("* ]]'
fresh; FAKE_SMI_FAIL=1 steno clip "$V" --out "$OUT" >/dev/null
check "nvidia-smi errors -> cpu" '[[ $(dev_of) == "device: cpu (nvidia-smi failed)" ]]'
fresh; FAKE_ENGINE_GPU=0 steno clip "$V" --out "$OUT" >/dev/null
check "no CUDA runtime -> cpu"   '[[ $(dev_of) == "device: cpu (installed sherpa-onnx has no CUDA support)" ]]'
# nvidia-smi missing: a PATH holding only the fake ffmpeg/ffprobe
mkdir -p "$W/nosmi"; ln -sf "$HERE/fakebin/ffmpeg" "$HERE/fakebin/ffprobe" "$(command -v head)" "$W/nosmi/"
fresh; PATH=$W/nosmi steno clip "$V" --out "$OUT" >/dev/null
check "nvidia-smi missing -> cpu" '[[ $(dev_of) == "device: cpu (nvidia-smi not found)" ]]'
# busy process: a copy of sleep named like the configured busy process
# (a shell script: the kernel names the process after the script file)
mkdir -p "$W/bin"; printf '#!/bin/sh\nsleep 300\n' > "$W/bin/steno-test-busy"; chmod +x "$W/bin/steno-test-busy"; "$W/bin/steno-test-busy" & BP=$!
sleep 0.2
fresh; steno clip "$V" --out "$OUT" >/dev/null
check "busy process running -> cpu" '[[ $(dev_of) == "device: cpu (busy process running: steno-test-busy)" ]]'
fresh; steno clip "$V" --out "$OUT" --device gpu >/dev/null
check "--device gpu ignores busy list" '[[ $(dev_of) == "device: gpu ("* ]]'
pkill -P $BP; kill $BP; wait $BP 2>/dev/null; sleep 0.1
fresh; steno clip "$V" --out "$OUT" >/dev/null
check "busy process gone -> gpu again" '[[ $(dev_of) == "device: gpu ("* ]]'
fresh; steno clip "$V" --out "$OUT" --device cpu >/dev/null
check "--device cpu with free GPU -> cpu" '[[ $(dev_of) == "device: cpu (--device cpu)" ]]'
check "default busy list has Kdenlive's render processes" '"$PY" -c "from stenographr.config import load; import os; os.environ[\"STENOGRAPHR_CONFIG\"]=\"/nonexistent\"; b=load().busy_processes; assert \"melt\" in b and \"kdenlive_render\" in b, b"'

echo "== checked before EACH file"
fresh; V1=$(mkvid 20261108_063820.mp4); V2=$(mkvid 20261108_070641.mp4)
printf '3500, 5\n1000, 5\n' > "$W/seq"
FAKE_SMI_SEQ=$W/seq steno clip "$V1" "$V2" --out "$OUT" >/dev/null
check "file 1 gpu, file 2 cpu"   '[[ $(dev_of 1) == "device: gpu ("* && $(dev_of 2) == "device: cpu (free VRAM 1000"* ]]'

echo "== GPU failure falls back to CPU"
fresh; FAKE_ENGINE_FAIL_GPU=1 steno clip "$V1" --out "$OUT" >/dev/null; echo $? > "$W/rc"
check "exit 0 and output written"  '[[ $(cat "$W/rc") == 0 && -f $OUT/20261108_063820.txt ]]'
check "txt says cpu"                'grep -q "^engine: fake (cpu) ·" "$OUT/20261108_063820.txt"'
check "failure logged as ERROR"    'grep -qE "ERROR 20261108_063820.mp4 GPU run failed, redoing on CPU: RuntimeError: fake CUDA failure" "$LOG"'


echo; echo "$pass passed, $fail failed"; [[ $fail == 0 ]]
