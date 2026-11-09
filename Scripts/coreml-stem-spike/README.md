# Core ML stem spike tooling (Phase 3a)

Offline conversion + parity helpers for replacing Continuity's ORT HT-Demucs FT
vocals specialist with a real Core ML `.mlpackage`.

**Cloud/Linux agents cannot finish conversion or device RSS.** Use a Mac for
`coremltools` prediction and the owner's iPhone for `StemSeparationBudget` A/B.

## Files

| File | Purpose |
|---|---|
| `convert_onnx_try.py` | Path A: direct ONNX → mlpackage (often fails; still run for evidence) |
| `convert_pytorch_path.py` | Path B: drive / document PyTorch rewrite converters |
| `parity_check.py` | One-window ORT vs Core ML vocals parity |
| `MEASUREMENT.md` | Device RSS + quality protocol |
| `requirements.txt` | Mac venv pins |

## App seams (already on this branch)

- `StemSeparating` + `StemStreamingEngine` — shared decode/OLA/encode
- `CoreMLStemSeparator` — `MLModel` backend (**not** wired into `PreparationQueue`)
- `StemWindowSpec` / `StemQualityMetrics` — Linux-tested contract + SI-SDR helpers
- `CoreMLStemModelStore` — Application Support path for a future package

Production remains `OnnxStemSeparator` + CPU EP only.
