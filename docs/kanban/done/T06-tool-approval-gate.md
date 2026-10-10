# T6 — Tool-approval gate

**Status:** done
**Commit:** `a566d93`

## Scope
`Sources/HarnessCore/Approval.swift`: policy, hook, and task-scoped "always allow". Set with `--approval` / `HARNESS_APPROVAL`. Confirms before `bash` runs; `spawn_agent` is approval-aware.

## Deferred
Per-tool allowlists, tracked in `backlog/T11-per-tool-approval-allowlists.md`.
