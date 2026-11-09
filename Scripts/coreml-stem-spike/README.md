# Core ML stem spike tooling (Phase 3a)

Offline conversion + parity helpers for replacing Continuity's ORT HT-Demucs FT
vocals specialist with a real Core ML `.mlpackage`.

**Hard rule:** never enable ORT CoreML EP. Candidate is `MLModel` + `.mlpackage`.

## Linux cloud status (2026-11 re-land)

| Path | How far | Outcome |
|---|---|---|
| A — `convert_onnx_try.py` | coremltools 9.0 imports; Continuity ONNX SHA verified | **Fail** — ONNX frontend removed (`source` ∈ {tensorflow, pytorch, milinternal} only) |
| B — dexxdean `convert.py --segment 7.8 --fp16` | demucs load 42 M → RealSTFT wrapper → forward → `torch.jit.trace` OK | **Fail** at `ct.convert` PyTorch→MIL (`TypeError: only 0-dimensional arrays can be converted to Python scalars` on `int` op); `libcoremlpython` absent on Linux |

No `.mlpackage` artifact was produced on Linux. Finish Path B on macOS (see spike doc runbook).

## Files

| File | Purpose |
|---|---|
| `convert_onnx_try.py` | Path A: direct ONNX → mlpackage (unavailable on modern coremltools) |
| `convert_pytorch_path.py` | Path B: drive / document PyTorch rewrite converters |
| `parity_check.py` | One-window ORT vs Core ML vocals parity |
| `MEASUREMENT.md` | Device RSS + quality protocol |
| `requirements.txt` | Mac venv pins |

## App seams (on the re-land branch)

- `StemSeparating` + `StemStreamingEngine` — shared decode/OLA/encode
- `CoreMLStemSeparator` — `MLModel` backend (**not** wired into `PreparationQueue`)
- `StemWindowSpec` / `StemQualityMetrics` — Linux-tested contract + SI-SDR helpers
- `CoreMLStemModelStore` — Application Support path for a future package

Production remains `OnnxStemSeparator` + CPU EP only.
