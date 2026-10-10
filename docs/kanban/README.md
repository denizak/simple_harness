# Kanban

One markdown file per task. A task's status is the folder it lives in:

| Folder | Meaning |
|---|---|
| `backlog/` | Agreed work, not started. |
| `inprogress/` | Someone is working on it now. Keep this short. |
| `done/` | Finished and merged to `main`. Kept as a record. |

Move a card with `git mv` so its history follows it.

## Card format

File name: `<ID>-<kebab-title>.md` (IDs continue the `T<n>` numbering from the old `docs/next-tasks.md`; new work uses the next free number).

```markdown
# T11 — Title

**Status:** backlog | inprogress | done
**Commit:** <hash, once done>

## Why
## Scope
## Acceptance
```

Every task ends with the shared gate: `swift test`, `swift run harness --selftest`, `swift build -c release`, `git diff --check`. Do not run `--e2e` routinely; it makes live provider calls.
