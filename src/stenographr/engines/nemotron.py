"""Streaming preview model for `live`: NVIDIA Nemotron speech streaming (English, 560 ms chunks, int8) through
sherpa-onnx's online recognizer. CPU only, 2 threads, ~1.3 GB of RAM.

It only paints the live text while the speaker talks: lowercase words, no punctuation, a new line after a pause.
The Parakeet clean pass at stop replaces it. Not used by `notes`.
Same stream interface as the Parakeet live stream: accept(audio) -> finished lines [{start, end, text}], flush(), and
`partial` (the line in progress).

Lines are cut here, from the token times, and the recognizer is never reset: its own endpointing resets the model, and a
reset drops the audio still in its pipeline (measured: 6-7 % of the words lost, "and we ... append" gone). A line ends
when no new word has come for LINE_GAP seconds of audio, or when it is LINE_MAX seconds long."""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np

from ..config import Config

SR = 16000
MODEL_DIR = "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25"
THREADS = 2
LINE_GAP = 1.8        # s of audio without a new word that ends a line (the model lags a word by ~0.6 s: about a 1.2 s pause)
LINE_MAX = 15.0       # s: a line this long is cut at the next word


def normalise(text: str) -> str:
    """lowercase, no punctuation (apostrophes stay: don't, it's)"""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s']", "", text.lower())).strip()


class NemotronStreamEngine:
    name = "nemotron-speech-streaming-en-0.6b-560ms-int8"

    def __init__(self, cfg: Config):
        import sherpa_onnx
        m = Path(cfg.models) / MODEL_DIR
        files = {k: m / v for k, v in (("encoder", "encoder.int8.onnx"), ("decoder", "decoder.int8.onnx"),
                                       ("joiner", "joiner.int8.onnx"), ("tokens", "tokens.txt"))}
        for f in files.values():
            if not f.is_file():
                raise FileNotFoundError(f"model file missing: {f}")
        self.rec = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=str(files["tokens"]), encoder=str(files["encoder"]), decoder=str(files["decoder"]),
            joiner=str(files["joiner"]), num_threads=THREADS, sample_rate=SR, provider="cpu",
            decoding_method="greedy_search")
        s = self.rec.create_stream()                       # warm-up: the first real chunk is not charged for lazy init
        s.accept_waveform(SR, np.zeros(SR // 10, dtype=np.float32))
        while self.rec.is_ready(s):
            self.rec.decode_stream(s)

    def stream(self) -> "_Stream":
        return _Stream(self.rec)


class _Stream:
    def __init__(self, rec):
        self.rec = rec
        self.s = rec.create_stream()
        self.fed = 0               # samples fed so far
        self.first = 0             # index of the first token of the line in progress
        self.partial = ""

    def _result(self):
        r = self.rec.get_result_all(self.s)
        return list(r.tokens), list(r.timestamps)

    def _cut(self, toks: list, ts: list, upto: int) -> dict | None:
        """The tokens first..upto as a finished line (None if it has no words)."""
        text = normalise("".join(toks[self.first:upto]))
        line = {"start": ts[self.first], "end": ts[upto - 1], "text": text} if text and upto <= len(ts) else None
        self.first = upto
        return line

    def _lines(self, toks: list, ts: list, final: bool) -> list[dict]:
        out = []
        now = self.fed / SR
        n = min(len(toks), len(ts))
        if final or (n > self.first and now - ts[n - 1] >= LINE_GAP):
            if n > self.first:
                line = self._cut(toks, ts, n)
                out += [line] if line else []
        else:
            while n > self.first + 1 and ts[n - 1] - ts[self.first] >= LINE_MAX:
                k = next((i for i in range(n - 1, self.first, -1) if toks[i].startswith(" ")), None)
                if k is None:
                    break
                line = self._cut(toks, ts, k)
                out += [line] if line else []
        self.partial = normalise("".join(toks[self.first:n]))
        return out

    def accept(self, audio: np.ndarray) -> list[dict]:
        self.s.accept_waveform(SR, audio.astype(np.float32, copy=False))
        self.fed += len(audio)
        while self.rec.is_ready(self.s):
            self.rec.decode_stream(self.s)
        toks, ts = self._result()
        return self._lines(toks, ts, final=False)

    def flush(self) -> list[dict]:
        self.s.accept_waveform(SR, np.zeros(int(0.6 * SR), dtype=np.float32))      # let the last chunk decode
        self.s.input_finished()
        while self.rec.is_ready(self.s):
            self.rec.decode_stream(self.s)
        toks, ts = self._result()
        out = self._lines(toks, ts, final=True)
        self.partial = ""
        return out
