# Phase 3a — device / Mac measurement plan

Continuity cloud agents cannot collect iPhone RSS. Run these on a Mac + the owner's
iPhone after a `.mlpackage` exists and `parity_check.py` passes.

## Hard rules

1. **Never** enable ORT `CoreMLExecutionProvider`. Compare:
   - **Baseline:** `OnnxStemSeparator` (CPU EP, graph opt `.none`, 1 thread, arena shrink)
   - **Candidate:** `CoreMLStemSeparator` loading a real `.mlpackage` via `MLModel`
2. Candidate default compute units: **`cpuAndGPU`**. Re-test `.all` only as a separate
   row — community HTDemucs reports say ANE can emit garbage.
3. Same `StemWindowSpec` (7.8 s / 25% overlap) and same `StemSeparationBudget` gates.

## Budget semantics to honor

| Gate | Value | Where |
|---|---|---|
| Start headroom | `AdaptiveQuality.stemRequiredStartMB()` (1400 / 1600 / 1800) | before model load |
| Window floor | `StemSeparationBudget.windowFloorMB` = 600 | before each window |
| Abort | memory warning → `requestAbort()` + `releaseSession()` | `PreparationQueue` |
| Hold after play | `stemHoldSeconds()` | unchanged |
| Limiter | 1 | unchanged |

A candidate **fails** if it cannot start under the same `requiredStartMB`, or if it
trips the window floor more often than ORT on the same track + tier.

## Metrics (collect for both backends)

| Metric | How |
|---|---|
| Peak RSS at model/session load | Console: subsystem `com.continuity.app`, category `mem` — delta from `ort/coreml … load begin` → `… ready` |
| Peak RSS first window | `mem[window 0]` vs pre-window headroom |
| Peak RSS mid-track | every 10th `mem[window N]` |
| Headroom at drain | after `releaseSession` / `separation done` |
| Wall time / RTF | harness timer for one ~3–4 min song |
| Quality | `StemQualityMetrics.siSDR` Core ML vocals vs ORT vocals (same mix); subjective duck on a blend |
| Jetsam / abort count | Diagnostics export + `AVFAudioGuard` unrelated; stem aborts from floor |

Suggested fixture set (same files both backends):

1. Short (~30 s) — load-dominated
2. Typical song (~3–4 min) — full streaming
3. Long (~15–20 min) — only if short/typical already win; confirm O(segment) still holds

Devices: at least one Air-class (tight jetsam) and one Pro if available. Record
`AdaptiveQuality` tier during the run.

## Mac harness (pre-device)

```bash
cd Scripts/coreml-stem-spike
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Path A — often fails; useful negative evidence
python convert_onnx_try.py --onnx "$ONNX" --out ./out/from_onnx.mlpackage

# Path B — community PyTorch rewrite (Mac only; Linux stops at ct.convert)
python convert_pytorch_path.py --converter-repo ~/src/htdemucs-coreml --fp16 \
    --out ./out/htdemucs_7p8_fp16.mlpackage

# Parity (required before device) — use ORT of the *same* weights you converted
python parity_check.py --onnx "$ONNX_OR_MATCHING" --mlpackage ./out/htdemucs_7p8_fp16.mlpackage
```

**dexxdean adaptations:** input/output names `audio`/`sources`; source order
vocals-first (index 0) vs Continuity ORT index 3; plain `htdemucs` ≠ StemSplitio FT.

Optional: drop the `.mlpackage` into Application Support
`StemModelCoreML/htdemucs_ft_vocals.mlpackage` (`CoreMLStemModelStore`) and temporarily
point a **local debug build** at `CoreMLStemSeparator` — do **not** merge that wire-up
until numbers win (Phase 3b).

## Simulator note

Simulator Core ML has no ANE and can be extremely slow; use it only for load/API
smoke, never for RSS go/no-go.

## Go / no-go bar (owner decision inputs)

**Go (fund Phase 3b wire-up)** only if on device:

- Session/model-load peak RSS **strictly below** ORT baseline (same song, same tier)
- No jetsam; abort rate ≤ ORT
- Vocals SI-SDR vs ORT ≥ ~20 dB on fixtures **or** owner signs subjective blend quality
- ANE (`.all`) is optional; CPU_AND_GPU win is enough to drop ORT later

**No-go (Phase 3c):** keep ORT; optionally try a **smaller** vocals ONNX; document that
Core ML EP remains banned.
