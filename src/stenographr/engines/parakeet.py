"""NVIDIA Parakeet TDT 0.6B v2 (int8) through sherpa-onnx, with Silero VAD to cut long audio.

File names and the `nemo_transducer` model type are from the sherpa-onnx docs
(pretrained_models/offline-transducer/nemo-transducer-models).
"""
from __future__ import annotations

import time
from pathlib import Path

import numpy as np

from ..config import Config

SR = 16000
MODEL_DIR = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
VAD_FILE = "silero_vad.onnx"


CHUNK_S = 30   # longest chunk of the clean pass, seconds


def merge_spans(spans: list[tuple[float, float]], max_s: float) -> list[tuple[float, float]]:
    """Merge consecutive speech spans (start, end) into chunks of at most ~max_s, splitting only at the longest
    pauses: when the window grows past max_s it is cut at its widest gap."""
    out: list[list[tuple[float, float]]] = []
    win: list[tuple[float, float]] = []
    for sp in spans:
        win.append(sp)
        while win[-1][1] - win[0][0] > max_s and len(win) > 1:
            gaps = [win[i + 1][0] - win[i][1] for i in range(len(win) - 1)]
            i = gaps.index(max(gaps))
            out.append(win[:i + 1])
            win = win[i + 1:]
    if win:
        out.append(win)
    return [(w[0][0], w[-1][1]) for w in out]


def gpu_runtime_available() -> bool:
    """True only for a CUDA build of sherpa-onnx (the plain PyPI wheel is CPU-only and would
    silently fall back to CPU if asked for `cuda`, which would make 'gpu' benchmarks lie)."""
    import sherpa_onnx
    pkg = Path(sherpa_onnx.__file__).parent
    libs = [pkg / "lib", pkg.parent / "sherpa_onnx_core" / "lib"]
    return "cuda" in sherpa_onnx.__version__ or any(
        any(d.glob("libonnxruntime_providers_cuda*")) for d in libs if d.is_dir())


def _preload_cuda_libs() -> None:
    """pip's nvidia-* wheels put CUDA/cuDNN in site-packages/nvidia/*/lib, which the dynamic loader
    does not search. Load them by hand (before sherpa-onnx's CUDA provider is) so that neither
    LD_LIBRARY_PATH nor an activated venv is needed."""
    import ctypes
    import importlib.util
    spec = importlib.util.find_spec("nvidia")
    for stem in ("libcudart", "libnvrtc", "libnvJitLink", "libcublasLt", "libcublas",
                 "libcufft", "libcurand", "libcudnn"):
        for base in (spec.submodule_search_locations if spec else []):
            for f in sorted(Path(base).glob(f"*/lib/{stem}.so.*")):
                try:
                    ctypes.CDLL(str(f), mode=ctypes.RTLD_GLOBAL)
                except OSError:
                    pass


class ParakeetEngine:
    name = "parakeet-tdt-0.6b-v2-int8"

    def __init__(self, cfg: Config, device: str):
        if device == "gpu":
            _preload_cuda_libs()
        import sherpa_onnx
        self._s = sherpa_onnx
        m = Path(cfg.models) / MODEL_DIR
        vad = Path(cfg.models) / VAD_FILE
        for f in (m / "encoder.int8.onnx", m / "decoder.int8.onnx", m / "joiner.int8.onnx",
                  m / "tokens.txt", vad):
            if not f.is_file():
                raise FileNotFoundError(f"model file missing: {f}")
        self.vad_model = str(vad)
        self.batch = cfg.batch_size if cfg.batch_size > 0 else (1 if device == "gpu" else 8)
        self.rec = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(m / "encoder.int8.onnx"),
            decoder=str(m / "decoder.int8.onnx"),
            joiner=str(m / "joiner.int8.onnx"),
            tokens=str(m / "tokens.txt"),
            num_threads=cfg.num_threads,
            sample_rate=SR,
            feature_dim=80,
            decoding_method="greedy_search",
            model_type="nemo_transducer",
            provider="cuda" if device == "gpu" else "cpu",
        )

    def _make_vad(self, min_silence: float, buffer_seconds: int, max_speech: float = 25):
        s = self._s
        c = s.VadModelConfig()
        c.silero_vad.model = self.vad_model
        c.silero_vad.threshold = 0.5
        c.silero_vad.min_silence_duration = min_silence
        c.silero_vad.min_speech_duration = 0.25
        c.silero_vad.max_speech_duration = max_speech   # Parakeet is happiest on short utterances
        c.sample_rate = SR
        return s.VoiceActivityDetector(c, buffer_size_in_seconds=buffer_seconds), c.silero_vad.window_size

    def _vad_segments(self, audio: np.ndarray) -> list[tuple[float, np.ndarray]]:
        vad, w = self._make_vad(0.4, 60)
        segs: list[tuple[float, np.ndarray]] = []

        def drain():
            while not vad.empty():
                f = vad.front
                segs.append((f.start / SR, np.asarray(f.samples, dtype=np.float32)))
                vad.pop()

        for i in range(0, len(audio) - w + 1, w):
            vad.accept_waveform(audio[i:i + w])
            drain()
        vad.flush()
        drain()
        return segs

    def _decode(self, batch: list[tuple[float, np.ndarray]]) -> list[dict]:
        streams = []
        for _, samples in batch:
            st = self.rec.create_stream()
            st.accept_waveform(SR, samples)
            streams.append(st)
        self.rec.decode_streams(streams)
        out = []
        for (start, samples), st in zip(batch, streams):
            text = st.result.text.strip()
            if text:
                out.append({"start": start, "end": start + len(samples) / SR, "text": text})
        return out

    def transcribe(self, audio: np.ndarray) -> list[dict]:
        segs = self._vad_segments(audio.astype(np.float32, copy=False))
        out = []
        for i in range(0, len(segs), self.batch):
            out += self._decode(segs[i:i + self.batch])
        return out

    def transcribe_long(self, audio: np.ndarray) -> list[dict]:
        """VAD with short pauses (0.3 s) and a 30 s cap, then neighbouring segments are merged into chunks of up to
        ~30 s, split only at the longest pauses, and each chunk is decoded in one go. That keeps sentences whole
        (the live stream cuts at every 0.6 s pause and loses the context). A 30 s chunk fits a 4 GB GPU easily
        (~1.2 GB peak measured, 60 s chunks too); batch size 1."""
        audio = audio.astype(np.float32, copy=False)
        vad, w = self._make_vad(0.3, 120, CHUNK_S)
        spans: list[tuple[float, float]] = []

        def drain():
            while not vad.empty():
                f = vad.front
                spans.append((f.start / SR, f.start / SR + len(f.samples) / SR))
                vad.pop()

        for i in range(0, len(audio) - w + 1, w):
            vad.accept_waveform(audio[i:i + w])
            drain()
        vad.flush()
        drain()
        out = []
        for start, end in merge_spans(spans, CHUNK_S):
            out += self._decode([(start, audio[int(start * SR):int(end * SR)])])
        return out

    def stream(self) -> "_Stream":
        return _Stream(self)


class _Stream:
    """Live dictation: the VAD is fed as audio arrives and each segment is decoded the moment the speaker
    pauses (0.6 s of silence)."""

    def __init__(self, eng: ParakeetEngine):
        self.eng = eng
        self.vad, self.w = eng._make_vad(0.6, 60)
        self.buf = np.zeros(0, dtype=np.float32)

    def _drain(self) -> list[dict]:
        out = []
        while not self.vad.empty():
            f = self.vad.front
            seg = (f.start / SR, np.asarray(f.samples, dtype=np.float32))
            self.vad.pop()
            out += self.eng._decode([seg])
        return out

    def accept(self, audio: np.ndarray) -> list[dict]:
        self.buf = np.concatenate([self.buf, audio.astype(np.float32, copy=False)])
        out = []
        while len(self.buf) >= self.w:
            self.vad.accept_waveform(self.buf[:self.w])
            self.buf = self.buf[self.w:]
            out += self._drain()
        return out

    def flush(self) -> list[dict]:
        self.vad.flush()
        return self._drain()
