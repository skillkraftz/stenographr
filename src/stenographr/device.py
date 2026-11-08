"""CPU/GPU choice, made before EACH file."""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import Config


@dataclass
class Decision:
    device: str   # "cpu" | "gpu"
    reason: str


def gpu_query() -> tuple[int, int] | None:
    """(free VRAM MiB, GPU utilization %) of the first GPU, or None if nvidia-smi is missing/broken."""
    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "--query-gpu=memory.free,utilization.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10, check=True).stdout
        free, util = (int(x) for x in out.strip().splitlines()[0].split(","))
        return free, util
    except (subprocess.SubprocessError, ValueError, IndexError, OSError):
        return None


def running_busy(names: list[str], proc: Path = Path("/proc")) -> list[str]:
    """Which of `names` are running right now (matched on the kernel's process name, `comm`)."""
    wanted, found = set(names), set()
    for d in proc.glob("[0-9]*"):
        try:
            comm = (d / "comm").read_text().strip()
        except OSError:
            continue
        if comm in wanted:
            found.add(comm)
    return sorted(found)


def decide(cfg: Config, requested: str, gpu_runtime_ok: bool) -> Decision:
    if requested == "cpu":
        return Decision("cpu", "--device cpu")
    if requested == "gpu":
        return Decision("gpu", "--device gpu (availability checks skipped)")
    if not shutil.which("nvidia-smi"):
        return Decision("cpu", "nvidia-smi not found")
    if not gpu_runtime_ok:
        return Decision("cpu", "installed sherpa-onnx has no CUDA support")
    q = gpu_query()
    if q is None:
        return Decision("cpu", "nvidia-smi failed")
    free, util = q
    need = cfg.vram_need_mib + cfg.vram_margin_mib
    if free < need:
        return Decision("cpu", f"free VRAM {free} MiB < needed {need} MiB")
    if util >= cfg.max_gpu_util_pct:
        return Decision("cpu", f"GPU busy: utilization {util}% >= {cfg.max_gpu_util_pct}%")
    busy = running_busy(cfg.busy_processes)
    if busy:
        return Decision("cpu", f"busy process running: {', '.join(busy)}")
    return Decision("gpu", f"free VRAM {free} MiB >= {need} MiB, utilization {util}% < "
                           f"{cfg.max_gpu_util_pct}%, no busy process")
