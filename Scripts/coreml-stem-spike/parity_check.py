#!/usr/bin/env python3
"""Compare one 7.8 s window: Continuity ORT ONNX vs Core ML .mlpackage.

Runs on Mac (needs coremltools + onnxruntime). Prints max-abs diff and a crude
SI-SDR on the vocals row. Thresholds mirror community HTDemucs converters:

  FP32: max |Δ| < 0.1
  FP16: max |Δ| < 0.2

This is conversion parity — NOT device RSS. RSS lives in MEASUREMENT.md.

Usage:
  python parity_check.py \\
      --onnx ~/…/htdemucs_ft_vocals_fp16weights.onnx \\
      --mlpackage ./out/htdemucs_ft_vocals.mlpackage \\
      [--wav fixture.wav]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

SEGMENT = 343_980
VOCALS = 3


def _si_sdr(estimate: np.ndarray, reference: np.ndarray) -> float:
    ref_energy = float(np.dot(reference, reference)) + 1e-12
    scale = float(np.dot(estimate, reference)) / ref_energy
    target = scale * reference
    noise = estimate - target
    return 10.0 * np.log10((np.dot(target, target) + 1e-12) / (np.dot(noise, noise) + 1e-12))


def _load_mix(wav: Path | None) -> np.ndarray:
    if wav is None:
        rng = np.random.default_rng(0)
        return rng.standard_normal((1, 2, SEGMENT), dtype=np.float32) * 0.1
    import soundfile as sf

    audio, sr = sf.read(str(wav), dtype="float32", always_2d=True)
    if sr != 44_100:
        raise SystemExit(f"fixture must be 44.1 kHz, got {sr}")
    planar = audio.T  # (ch, t)
    if planar.shape[0] == 1:
        planar = np.tile(planar, (2, 1))
    planar = planar[:2]
    if planar.shape[1] < SEGMENT:
        planar = np.pad(planar, ((0, 0), (0, SEGMENT - planar.shape[1])))
    else:
        planar = planar[:, :SEGMENT]
    return planar[np.newaxis, ...].astype(np.float32)


def _run_onnx(path: Path, mix: np.ndarray) -> np.ndarray:
    import onnxruntime as ort

    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    stems = sess.run(["stems"], {"mix": mix})[0]
    return stems  # (1, 4, 2, T)


def _run_coreml(path: Path, mix: np.ndarray) -> np.ndarray:
    import coremltools as ct

    model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    # Accept either Continuity names (mix/stems) or community (audio/sources).
    spec_in = model.get_spec().description.input[0].name
    spec_out = model.get_spec().description.output[0].name
    out = model.predict({spec_in: mix})
    stems = np.array(out[spec_out], dtype=np.float32)
    if stems.ndim == 3 and stems.shape[1] == 8:
        # Flattened [1, 8, T] → [1, 4, 2, T]
        stems = stems.reshape(1, 4, 2, stems.shape[-1])
    return stems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--mlpackage", type=Path, required=True)
    parser.add_argument("--wav", type=Path, default=None)
    parser.add_argument("--max-diff", type=float, default=0.2)
    parser.add_argument("--min-sisdr", type=float, default=20.0)
    args = parser.parse_args()

    mix = _load_mix(args.wav)
    print(f"mix shape {mix.shape}")

    onnx_stems = _run_onnx(args.onnx, mix)
    core_stems = _run_coreml(args.mlpackage, mix)
    if onnx_stems.shape != core_stems.shape:
        print(f"shape mismatch onnx={onnx_stems.shape} coreml={core_stems.shape}", file=sys.stderr)
        return 1

    voc_onnx = onnx_stems[0, VOCALS].reshape(-1)
    voc_core = core_stems[0, VOCALS].reshape(-1)
    max_diff = float(np.max(np.abs(voc_onnx - voc_core)))
    sisdr = _si_sdr(voc_core, voc_onnx)
    print(f"vocals max|Δ| = {max_diff:.6f}")
    print(f"vocals SI-SDR (CoreML vs ORT) = {sisdr:.2f} dB")

    ok = max_diff <= args.max_diff and sisdr >= args.min_sisdr
    if not ok:
        print("PARITY FAIL — do not proceed to device RSS / Phase 3b.", file=sys.stderr)
        return 1
    print("PARITY OK under thresholds — proceed to MEASUREMENT.md on device.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
