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
BATCH = 8   # VAD segments decoded together


def gpu_runtime_available() -> bool:
    """True only for a CUDA build of sherpa-onnx (the plain PyPI wheel is CPU-only and would
    silently fall back to CPU if asked for `cuda`, which would make 'gpu' benchmarks lie)."""
    import sherpa_onnx
    pkg = Path(sherpa_onnx.__file__).parent
    libs = [pkg / "lib", pkg.parent / "sherpa_onnx_core" / "lib"]
    return "cuda" in sherpa_onnx.__version__ or any(
        any(d.glob("libonnxruntime_providers_cuda*")) for d in libs if d.is_dir())


class ParakeetEngine:
    name = "parakeet-tdt-0.6b-v2-int8"

    def __init__(self, cfg: Config, device: str):
        import sherpa_onnx
        self._s = sherpa_onnx
        m = Path(cfg.models) / MODEL_DIR
        vad = Path(cfg.models) / VAD_FILE
        for f in (m / "encoder.int8.onnx", m / "decoder.int8.onnx", m / "joiner.int8.onnx",
                  m / "tokens.txt", vad):
            if not f.is_file():
                raise FileNotFoundError(f"model file missing: {f}")
        self.vad_model = str(vad)
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

    def _vad_segments(self, audio: np.ndarray) -> list[tuple[float, np.ndarray]]:
        s = self._s
        c = s.VadModelConfig()
        c.silero_vad.model = self.vad_model
        c.silero_vad.threshold = 0.5
        c.silero_vad.min_silence_duration = 0.4
        c.silero_vad.min_speech_duration = 0.25
        c.silero_vad.max_speech_duration = 25     # Parakeet is happiest on short utterances
        c.sample_rate = SR
        vad = s.VoiceActivityDetector(c, buffer_size_in_seconds=60)
        w = c.silero_vad.window_size
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

    def transcribe(self, audio: np.ndarray) -> list[dict]:
        segs = self._vad_segments(audio.astype(np.float32, copy=False))
        out = []
        for i in range(0, len(segs), BATCH):
            batch = segs[i:i + BATCH]
            streams = []
            for _, samples in batch:
                st = self.rec.create_stream()
                st.accept_waveform(SR, samples)
                streams.append(st)
            self.rec.decode_streams(streams)
            for (start, samples), st in zip(batch, streams):
                text = st.result.text.strip()
                if text:
                    out.append({"start": start, "end": start + len(samples) / SR, "text": text})
        return out
