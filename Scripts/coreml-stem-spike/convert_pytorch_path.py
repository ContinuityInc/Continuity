#!/usr/bin/env python3
"""Path B: convert HT-Demucs via PyTorch → Core ML .mlpackage.

Direct ONNX conversion (convert_onnx_try.py) is dead on modern coremltools (no ONNX
frontend) and, historically, died on complex STFT / fused MultiheadAttention /
scatter_add. Community converters solve this by:

  1. Real-valued STFT/ISTFT (no complex64 in the traced graph)
  2. Manual multi-head attention (no _native_multi_head_attention)
  3. Pre-computed OLA index buffers for ISTFT

This script is a *driver + contract check*, not a full reimplementation of those
~600 LoC workarounds. On a Mac it either:

  - Invokes a local checkout of dexxdean/htdemucs-coreml (`--converter-repo`), or
  - Prints the exact clone/convert commands if the repo is missing.

Target Continuity contract (`StemWindowSpec`):
  input  mix   [1, 2, 343980] float32
  output stems [1, 4, 2, 343980] float32  OR flattened [1, 8, 343980]
               source order drums, bass, other, vocals — Continuity uses index 3

dexxdean defaults differ — adapt before CoreMLStemSeparator A/B:
  - input name `audio` (not `mix`); output name `sources` (separator falls back)
  - source order **vocals, drums, bass, other** → vocals at index **0**, not 3
  - model is plain `htdemucs` (~42 M), not Continuity's StemSplitio
    `htdemucs_ft_vocals` specialist ONNX — parity is against ORT of the *same*
    weights you convert, not against the production ONNX unless you re-export FT

Compute units: CPU_AND_GPU by default. Do NOT ship ALL/ANE without parity proof —
HTDemucs on ANE is known to emit incorrect audio in community reports.

Linux note (2026-11 cloud spike): load + RealSTFT wrapper + jit.trace succeed for
7.8 s / FP16; `ct.convert` then fails early (`TypeError` on `int` cast in the
PyTorch→MIL frontend) and `libcoremlpython` is absent. Finish conversion on macOS.

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

    # dexxdean CLI: --segment <seconds float>, --fp16, --output
    cmd = [
        sys.executable,
        str(convert_py),
        "--segment",
        "7.8",
        "--output",
        str(args.out),
    ]
    if args.fp16:
        cmd.append("--fp16")
    print("running:", " ".join(cmd))
    print("HARD RULE: .mlpackage via MLModel — never ORT CoreMLExecutionProvider.")
    print(
        "Continuity adaptations after success: rename audio→mix / sources→stems "
        "(or keep names — CoreMLStemSeparator falls back), map vocals index 0→3 "
        "OR disable SOURCE_REORDER, then parity_check.py."
    )
    proc = subprocess.run(cmd, cwd=str(args.converter_repo), check=False)
    if proc.returncode != 0:
        return proc.returncode

    print(
        f"Converter finished → {args.out}. "
        "Run parity_check.py against the ORT vocals of the *same* weights."
    )
    return 0


def _print_manual_commands(out: Path, fp16: bool) -> None:
    flag = " --fp16" if fp16 else ""
    print(
        f"""
No --converter-repo supplied. On an Apple Silicon Mac with ≥16 GB RAM
(dexxdean verified: Python 3.9, torch/torchaudio 2.8.0, coremltools 9.0, demucs 4.0.1):

  git clone https://github.com/dexxdean/htdemucs-coreml.git
  cd htdemucs-coreml
  python3 -m venv venv && source venv/bin/activate
  pip install -r requirements.txt
  # Prefer verified pins if the float range pulls a broken combo:
  #   pip install 'torch==2.8.0' 'torchaudio==2.8.0' 'coremltools==9.0' 'demucs==4.0.1'
  python convert.py --segment 7.8{flag} --output {out}

Then adapt to Continuity StemWindowSpec / CoreMLStemSeparator:
  - Prefer tensor names mix / stems (separator also accepts sources)
  - dexxdean SOURCE_REORDER → vocals at index 0; Continuity ORT uses index 3
    (drums, bass, other, vocals). Either undo the reorder at export or teach the
    separator which index is vocals for that package.
  - Package is plain htdemucs, not StemSplitio htdemucs_ft_vocals — A/B vs ORT
    of the *converted* weights, not vs production ONNX, unless you also convert FT.

Install into Application Support (see CoreMLStemModelStore):
  cp -R {out} \"$HOME/Library/Application Support/StemModelCoreML/htdemucs_ft_vocals.mlpackage\"

Parity (Mac):
  python Scripts/coreml-stem-spike/parity_check.py \\
      --onnx /path/to/matching.onnx \\
      --mlpackage {out}

Device RSS (iPhone, Console filter subsystem com.continuity.app category mem):
  see MEASUREMENT.md — do not merge wire-up until peak RSS wins under StemSeparationBudget.
""".strip()
    )


if __name__ == "__main__":
    raise SystemExit(main())
