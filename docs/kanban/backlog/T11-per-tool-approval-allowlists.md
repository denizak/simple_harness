# T11 — Per-tool approval allowlists

**Status:** backlog

## Why
The approval gate (T6) only offers task-scoped "always allow". The named follow-up is rules like "always allow `read_file`, ask for `bash`". README "Where to go next" #2.

## Scope
- Allowlist keyed by tool name (and optionally argument pattern), set from config and flags.
- Applies to sub-agents spawned via `spawn_agent`.
- Update any allowlists that still say `judge` (renamed `naluri` in T8).

## Acceptance
Offline tests with a scripted model: allowlisted tool runs without a prompt, others still prompt, sub-agents inherit the list.
