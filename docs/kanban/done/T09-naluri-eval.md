# T9 — naluri eval

**Status:** done
**Commit:** `4bcdadf`

## Scope
`NaluriEval.swift` and `--eval-naluri`. `Evals/naluri.json` holds 70 labelled cases (40 easy, 30 hard with `alsoAccept`). Metrics: accuracy, Brier, overconfidence, confidence when wrong, latency, tokens, estimated cost; spend cap via `--eval-budget`.

## Result
All three backends score 96% overall and 90% on hard cases. Calibration separates them: Jev's confidence drops on hard cases (0.80) and its misses sit near 0.5; DeepSeek and GLM are confidently wrong. The gate stays on Jev.

## Open
The gate threshold (0.45) is untuned; see `backlog/T12-tune-naluri-gate-threshold.md`.
