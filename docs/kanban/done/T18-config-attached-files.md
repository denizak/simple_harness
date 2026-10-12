# T18 — Config-file `attachedFiles`: always-attached context files

**Status:** done
**Commit:** 0f5ab36

## Why
Standing instructions (AGENTS.md / CLAUDE.md style) had to be re-supplied by
hand every session. The model should see them from the very first call
without anyone pasting them into the task.

## Scope
- New config-file key `attachedFiles` (array of paths, cwd-relative) on
  `Config`; parsed in `applyFileEntries` alongside the other keys, so
  flags/env still outrank the file.
- `systemPrompt(for:)` appends each file's contents under a
  `# Attached file: <path>` header (`attachedFilesPrompt`). Applies to both
  the REPL and `--once`. A missing file warns and is skipped — attachment is
  a convenience, not a dependency.
- Compaction keeps the leading system message, so attachments survive it.
  No auto-discovery of AGENTS.md when the key is absent, by design; spawned
  sub-agents keep their own narrow prompt.

## Acceptance
`--selftest` passes with the new `attachedFilesChecks` section (config
parsing, contents verbatim in the prompt, empty-when-unset, missing-file
skip). Release build clean. `swift test` has one pre-existing failure in the
eval soundness case `fix-bug-add` that also fails on clean `main`
(Python-environment, unrelated).
