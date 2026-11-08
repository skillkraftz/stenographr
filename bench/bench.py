#!/usr/bin/env python3
"""Benchmark `stenographr clip` on real videos. Outputs ONLY under /tmp/stenographr-bench.

For each video x device (cpu, gpu) x (alone, concurrent with an nvenc ffmpeg encode of another
original): wall time, realtime factor, peak RAM (/usr/bin/time -v), peak VRAM (nvidia-smi, this
process's own and whole-GPU), model load time (from steno.log). Also compares original vs clip
durations with ffprobe.

  python3 bench/bench.py VIDEO... --clips-dir DIR
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, threading, time
from pathlib import Path

BENCH = Path("/tmp/stenographr-bench")
ARCHIVE = BENCH / "archive"


def smi(q):
    try:
        return subprocess.run(["nvidia-smi", f"--query-{q[0]}={q[1]}", "--format=csv,noheader,nounits"],
                              capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
    except Exception:
        return []


def children(pid):
    out = []
    for t in Path(f"/proc/{pid}/task").glob("*"):
        try:
            out += [int(x) for x in (t / "children").read_text().split()]
        except OSError:
            pass
    return out


def descendants(pid):
    todo, seen = [pid], set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        todo += children(p)
    return seen


class VramSampler(threading.Thread):
    def __init__(self, root_pid_fn):
        super().__init__(daemon=True)
        self.stop = threading.Event()
        self.root = root_pid_fn
        self.peak_total = self.peak_own = 0
        self.base = int(smi(("gpu", "memory.used"))[0])

    def run(self):
        while not self.stop.is_set():
            rows = smi(("gpu", "memory.used"))
            if rows:
                self.peak_total = max(self.peak_total, int(rows[0]))
            pid = self.root()
            if pid:
                mine = descendants(pid)
                for r in smi(("compute-apps", "pid,used_memory")):
                    try:
                        p, m = (int(x) for x in r.split(","))
                    except ValueError:
                        continue
                    if p in mine:
                        self.peak_own = max(self.peak_own, m)
            self.stop.wait(0.3)


def probe(path):
    j = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "format=duration,start_time:stream=codec_type,duration,start_time", "-of", "json", str(path)],
        capture_output=True, text=True).stdout)
    d = {"format": float(j["format"]["duration"]), "start": float(j["format"].get("start_time", 0))}
    for s in j["streams"]:
        if "duration" in s:
            d[s["codec_type"]] = float(s["duration"])
    return d


def run_one(video, device, mode, other, tag):
    out = BENCH / "out" / tag
    cfg = BENCH / "config.toml"
    cmd = ["/usr/bin/time", "-v", "stenographr", "--config", str(cfg), "clip", str(video),
           "--out", str(out), "--device", device]
    ff = None
    ffout = BENCH / f"nvenc-{tag}.mp4"
    if mode == "concurrent":
        ff = subprocess.Popen(
            ["ffmpeg", "-y", "-hide_banner", "-stream_loop", "-1", "-i", str(other), "-c:v", "h264_nvenc",
             "-preset", "p5", "-c:a", "aac", str(ffout)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        time.sleep(4)   # let the encoder get going
    holder = {}
    smp = VramSampler(lambda: holder.get("pid"))
    smp.start()
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    holder["pid"] = p.pid
    _, err = p.communicate()
    wall = time.monotonic() - t0
    smp.stop.set(); smp.join()
    enc_speed = None
    if ff:
        ff.send_signal(signal.SIGINT)
        try:
            e = ff.communicate(timeout=30)[1]
            sp = re.findall(r"speed=\s*([\d.]+)x", e)
            enc_speed = float(sp[-1]) if sp else None
        except subprocess.TimeoutExpired:
            ff.kill()
        ffout.unlink(missing_ok=True)
    ram = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    rc = p.returncode
    log = (ARCHIVE / "steno.log").read_text().splitlines()
    timing = [l for l in log if " timing: " in l][-1] if rc == 0 else ""
    m = re.search(r"device=(\w+) audio=([\d.]+)s load=([\d.]+)s transcribe=([\d.]+)s", timing)
    return {
        "video": Path(video).stem, "device": device, "mode": mode, "rc": rc,
        "wall": wall, "ram_gb": int(ram.group(1)) / 1e6 if ram else None,
        "vram_own": smp.peak_own or None, "vram_gpu_delta": smp.peak_total - smp.base,
        "device_used": m.group(1) if m else None, "audio": float(m.group(2)) if m else None,
        "load": float(m.group(3)) if m else None, "transcribe": float(m.group(4)) if m else None,
        "enc_speed": enc_speed, "err": err[-300:] if rc else "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("videos", nargs="+")
    ap.add_argument("--clips-dir", required=True)
    a = ap.parse_args()
    assert BENCH.exists()
    results = []
    vids = a.videos
    for i, v in enumerate(vids):
        other = vids[(i + 1) % len(vids)]
        for mode in ("alone", "concurrent"):
            for dev in ("cpu", "gpu"):
                tag = f"{Path(v).stem}-{dev}-{mode}"
                print("running", tag, flush=True)
                r = run_one(v, dev, mode, other, tag)
                r["rtf"] = r["transcribe"] / r["audio"] if r["audio"] else None
                r["wall_rtf"] = r["wall"] / r["audio"] if r["audio"] else None
                print(json.dumps(r), flush=True)
                results.append(r)
                (BENCH / "results.json").write_text(json.dumps(results, indent=1))
    dur = []
    for v in vids:
        clip = Path(a.clips_dir) / Path(v).name
        dur.append({"video": Path(v).stem, "orig": probe(v), "clip": probe(clip)})
    (BENCH / "durations.json").write_text(json.dumps(dur, indent=1))


if __name__ == "__main__":
    main()
