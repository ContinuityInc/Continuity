#!/usr/bin/env python3
"""Path B: convert HT-Demucs FT vocals specialist via PyTorch → Core ML .mlpackage.

Direct ONNX conversion (convert_onnx_try.py) usually dies on complex STFT,
fused MultiheadAttention, or fragile scatter_add. Community converters solve this by:

  1. Real-valued STFT/ISTFT (no complex64 in the traced graph)
  2. Manual multi-head attention (no _native_multi_head_attention)
  3. Pre-computed OLA index buffers for ISTFT

This script is a *driver + contract check*, not a full reimplementation of those
~600 LoC workarounds. On a Mac it either:

  - Invokes a local checkout of dexxdean/htdemucs-coreml (`--converter-repo`), or
  - Prints the exact clone/convert commands if the repo is missing.

Target contract (must match Continuity `StemWindowSpec`):
  input  mix   [1, 2, 343980] float32
  output stems [1, 4, 2, 343980] float32  OR flattened [1, 8, 343980]
               source order drums, bass, other, vocals — Continuity uses index 3

Compute units: CPU_AND_GPU by default. Do NOT ship ALL/ANE without parity proof —
HTDemucs on ANE is known to emit incorrect audio in community reports.

Usage:
  python convert_pytorch_path.py --out ./out/htdemucs_ft_vocals.mlpackage
  python convert_pytorch_path.py --converter-repo ~/src/htdemucs-coreml --fp16
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SEGMENT = 343_980
SAMPLE_RATE = 44_100


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--converter-repo",
        type=Path,
        default=None,
        help="Local clone of https://github.com/dexxdean/htdemucs-coreml (or equivalent)",
    )
    parser.add_argument("--fp16", action="store_true", help="Ask converter for FP16 weights")
    parser.add_argument(
        "--segment-seconds",
        type=float,
        default=7.8,
        help="Must stay 7.8 to match Continuity's StemWindowSpec / ONNX",
    )
    args = parser.parse_args()

    segment = int(round(args.segment_seconds * SAMPLE_RATE))
    if segment != SEGMENT:
        print(
            f"error: segment {segment} != Continuity StemWindowSpec ({SEGMENT}). "
            "Re-run with --segment-seconds 7.8 or update StemWindowSpec + ORT together.",
            file=sys.stderr,
        )
        return 2

    if args.converter_repo is None:
        _print_manual_commands(args.out, args.fp16)
        return 0

    convert_py = args.converter_repo / "convert.py"
    if not convert_py.is_file():
        print(f"error: no convert.py in {args.converter_repo}", file=sys.stderr)
        _print_manual_commands(args.out, args.fp16)
        return 2

    cmd = [sys.executable, str(convert_py), "--segment", "7.8"]
    if args.fp16:
        cmd.append("--fp16")
    print("running:", " ".join(cmd))
    print("HARD RULE: .mlpackage via MLModel — never ORT CoreMLExecutionProvider.")
    proc = subprocess.run(cmd, cwd=str(args.converter_repo), check=False)
    if proc.returncode != 0:
        return proc.returncode

    print(
        f"Converter finished in {args.converter_repo}. Copy the .mlpackage to {args.out}, "
        "then run parity_check.py against Continuity's ORT vocals specialist."
    )
    print(
        "NOTE: dexxdean defaults may use input name 'audio' and 10 s segments — "
        "re-export with 7.8 s and rename tensors to mix/stems before CoreMLStemSeparator."
    )
    return 0


def _print_manual_commands(out: Path, fp16: bool) -> None:
    flag = " --fp16" if fp16 else ""
    print(
        f"""
No --converter-repo supplied. On an Apple Silicon Mac with ≥16 GB RAM:

  git clone https://github.com/dexxdean/htdemucs-coreml.git
  cd htdemucs-coreml
  python3 -m venv venv && source venv/bin/activate
  pip install -r requirements.txt
  python convert.py --segment 7.8{flag}

Then adapt tensor names/shapes to Continuity's StemWindowSpec:
  mix:   (1, 2, {SEGMENT})
  stems: (1, 4, 2, {SEGMENT})   # vocals = source index 3

Install into the app's Application Support spike path (see CoreMLStemModelStore):
  cp -R HTDemucs_CoreML*.mlpackage {out}

Parity (Mac):
  python Scripts/coreml-stem-spike/parity_check.py \\
      --onnx /path/to/htdemucs_ft_vocals_fp16weights.onnx \\
      --mlpackage {out}

Device RSS (iPhone, Console filter subsystem com.continuity.app category mem):
  see MEASUREMENT.md — do not merge to main until peak RSS wins under StemSeparationBudget.
""".strip()
    )


if __name__ == "__main__":
    raise SystemExit(main())
