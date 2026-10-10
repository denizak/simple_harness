# T17 — Restore `docs/next-tasks.md`

**Status:** done
**Commit:** 1f3f5cb

## Why
`docs/next-tasks.md` was a 1-byte file at `HEAD`, emptied in `f6c917d` and `308c994` (and cut to one paragraph in `a421f90`).

**Cause (found):** not the agent eval. It was a bug in the assistant's own fix-up commands: in Python, `open(p, "w").write(open(p).read().rstrip("\n") + "\n")` truncates the file *before* the inner `open(p).read()` runs, so it reads an empty string and writes it back. The eval never touched the repo's docs. The README sizes across those commits only grow, so no other file was hit.

## Scope
Restored from `dede4b7` (the last full copy, 33.6 KB) and re-added the sections written after it: the harder agent set, the hard-set glm and deepseek results, and the reproduction attempt.

## Acceptance
README link resolves to real content (37 KB, T1–T10 plus eval findings) and the file is intact at `HEAD`. Edit docs by reading into a variable first, then writing; never `open(p, "w")` and `open(p)` in one expression.
