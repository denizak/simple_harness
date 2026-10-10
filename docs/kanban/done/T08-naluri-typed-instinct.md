# T8 — naluri: vendor-neutral typed instinct

**Status:** done
**Commit:** `73dc73c`

## Scope
Replaced the vendor-tied `judge` tool with `naluri`: fast typed gut-calls with probabilities. Vendor-neutral core in `Naluri.swift`; TypeSafe/Jev client in `TypeSafe.swift`; chat backends (deepseek, zai) in `ChatNaluri.swift` using one-token answers and `top_logprobs`. Config via `HARNESS_NALURI`, `--naluri`, `--naluri-model`.

## Findings
DeepSeek returns logprobs; z.ai returns none, so GLM answers are one-hot and flagged `uncalibrated`. Follow-ups: provider env key beats config `apiKey` (`a21ccf6`), per-provider model in the catalog (`c6b6796`), no retry on out-of-balance 429 (`8064368`), token headroom for thinking-only models (`3345262`).
