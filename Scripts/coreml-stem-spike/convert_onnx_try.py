#!/usr/bin/env python3
"""Attempt a direct ONNX → Core ML .mlpackage conversion of Continuity's model.

This is Path A of the Phase 3a spike: convert the exact artifact Continuity already
downloads (`htdemucs_ft_vocals_fp16weights.onnx` from StemSplitio) without going
through PyTorch again.

Expected outcome on a Mac with coremltools:
  - Often FAILS on HT-Demucs because of complex STFT / MultiheadAttention / scatter_add
    ops (see convert_pytorch_path.py and docs/coreml-stem-spike.md).
  - If it succeeds, still MUST run parity + device RSS before any production wire-up.
  - NEVER use ONNX Runtime's CoreMLExecutionProvider as a substitute — that path is
    banned in Continuity (jetsam at session creation).

Usage (Apple Silicon Mac):
  python3 -m venv .venv && source .venv/bin/activate
  pip install -r requirements.txt
  python convert_onnx_try.py \\
      --onnx ~/Library/Application\\ Support/.../htdemucs_ft_vocals_fp16weights.onnx \\
      --out ./out/htdemucs_ft_vocals.mlpackage
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


SEGMENT = 343_980  # StemWindowSpec.segmentFrames


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=Path, required=True, help="Path to Continuity ONNX weights")
    parser.add_argument("--out", type=Path, required=True, help="Output .mlpackage path")
    parser.add_argument(
        "--precision",
        choices=("fp16", "fp32"),
        default="fp16",
        help="Core ML compute precision (fp16 matches Continuity's ONNX weights)",
    )
    args = parser.parse_args()

    if not args.onnx.is_file():
        print(f"error: ONNX not found: {args.onnx}", file=sys.stderr)
        return 2

    try:
        import coremltools as ct
    except ImportError:
        print(
            "error: coremltools not installed. Run on macOS:\n"
            "  python3 -m venv .venv && source .venv/bin/activate\n"
            "  pip install -r requirements.txt",
            file=sys.stderr,
        )
        return 2

    precision = ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    print(f"converting {args.onnx} → {args.out} ({args.precision})")
    print("HARD RULE: this produces an .mlpackage for MLModel — not ORT CoreML EP.")

    try:
        mlmodel = ct.convert(
            str(args.onnx),
            inputs=[ct.TensorType(name="mix", shape=(1, 2, SEGMENT))],
            outputs=[ct.TensorType(name="stems")],
            minimum_deployment_target=ct.target.iOS17,
            convert_to="mlprogram",
            compute_precision=precision,
            compute_units=ct.ComputeUnit.CPU_AND_GPU,  # ANE often wrong for HTDemucs
        )
    except Exception as exc:  # noqa: BLE001 — surface converter failures verbatim
        print("DIRECT ONNX→Core ML FAILED (expected for many HT-Demucs exports).", file=sys.stderr)
        print(f"  {type(exc).__name__}: {exc}", file=sys.stderr)
        print(
            "Next: use convert_pytorch_path.py (RealSTFT + ManualMHA rewrite), "
            "or vendor a known-good community converter (dexxdean/htdemucs-coreml).",
            file=sys.stderr,
        )
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.author = "Continuity Phase 3a spike"
    mlmodel.short_description = (
        "HT-Demucs FT vocals specialist. Input mix [1,2,343980] @ 44.1 kHz. "
        "Output stems [1,4,2,343980]; use source index 3 (vocals)."
    )
    mlmodel.save(str(args.out))
    print(f"wrote {args.out}")
    print("Next: python parity_check.py --onnx … --mlpackage … then device RSS harness.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
