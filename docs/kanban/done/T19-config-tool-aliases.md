# T19 — Config-file `toolAliases`: run a tool through another command

**Status:** done
**Commit:** 974d3c7

## Why
Let a tool's execution be swapped for a better backend without changing the
model-facing surface. Motivating case: route the `grep` tool to ripgrep
(`rg`) — one round-trip for the model, ripgrep's speed underneath. (fff was
considered first but ships no stdout CLI — SDK/MCP only — so it does not fit
a shell-template alias today.)

## Scope
- Config-file key `toolAliases`: `{toolName: shellTemplate}`.
- `Tools.ToolAlias` substitutes `{arg}` placeholders with shell-quoted
  argument values (strings verbatim, bools `true`/`false`, numbers as
  integers); placeholders without a matching argument are left intact so the
  aliased command's own defaults apply.
- `Agent.execute` checks the alias after the approval gate and before the
  built-in `tool.run`, so aliasing can never bypass approval.
- Same output contract as built-ins: bounded ShellRunner run, result text
  capped by `maxToolOutput`, failures as text.

## Acceptance
`--selftest` passes with the new `toolAliasChecks` section: config parsing,
substitution + injection-safe quoting, untouched `{missing}` placeholders,
and a live template run. Release build clean; `rg` present on PATH.
`swift test` retains only the pre-existing `fix-bug-add` environment failure.
