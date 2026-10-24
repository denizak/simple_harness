# T21 — Token usage display: `/usage`, per-turn context, window table

**Status:** done
**Commit:** 92d8fe0

## Why
A long session can approach the model's context window silently: requests
start failing or get compacted with no visibility into why. Chat APIs resend
the whole history every turn, so the *last* turn's
`usage.prompt + usage.completion` is the live context size — once you track
it, the natural companion is the window it should be compared against.

## Scope
- `Sources/HarnessCore/Providers.swift` — `ProviderProfile.contextWindows`:
  a per-model map plus a provider-wide default, covering openai (4o/4o-mini
  128k, o3/o4-mini 200k, gpt-5 400k), zai (glm family 200k), anthropic
  (sonnet 200k, opus 200k/400k entries as documented), ollama
  (kimi-k2.7-code 262_144). Models with no documented window fall through.
- `Config.swift` — `contextWindow` resolution precedence:
  `HARNESS_CONTEXT_WINDOW` env override (≤0 or unparsable = unknown →
  ratio suppressed) > per-model entry > provider default > nil.
- `Agent.swift` — `totalPromptTokens`/`totalCompletionTokens` accumulate
  per turn; `contextTokens` holds the last turn's prompt+completion.
  `recordUsage(promptTokens:completionTokens:)` is the test/selftest seam
  that mirrors exactly what the run loop does with `turn.usage`.
  `resetUsage()` clears totals (`/reset` starts the conversation over, so
  the accounting does too). `usageSummary()` renders
  `"N tokens so far — context X/Y (P%)"`, ratio only when a window is known
  and there has been at least one turn; `≥81%` appends `⚠︎` (same threshold
  as the existing compaction warning).
- `Sources/harness/Harness.swift` — turn lines gain `ctx X/Y` once a window
  is known; `/usage` prints the full summary; `/reset` calls `resetUsage`.
- `Sources/harness/Selftest.swift` — `usageChecks`: window precedence,
  env override, accumulation vs. last-turn semantics, threshold flag,
  reset.
- `Tests/HarnessTests/UsageAccountingTests.swift` — 4 Swift Testing tests.
- README: slash-command and environment-override lists updated.

## Acceptance
`swift test` green (113 tests); `swift run harness --selftest` passes with
the new `usageChecks` section (9 checks); `swift build -c release` clean;
`git diff --check` clean.

## Out of scope
- Cached-token accounting (`usage` carries cache fields on some providers;
  totals count raw prompt tokens).
- Rendering the ratio inside the streaming spinner (only turn end + `/usage`).
- Compact-trigger automation off the percentage (the ≥81% mark is advisory,
  matching the existing compaction warn).
- Per-request cost estimation.
