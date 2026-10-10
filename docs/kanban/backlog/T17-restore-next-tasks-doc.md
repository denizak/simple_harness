# T17 — Restore or retire `docs/next-tasks.md`

**Status:** backlog

## Why
`docs/next-tasks.md` is a 1-byte file at `HEAD`. It was emptied in `f6c917d` and again in `308c994`; the last full copy (about 33 KB, T1–T10 narrative and eval findings) is at `dede4b7`, and a shorter eval-notes version at `a421f90`. The cards under `done/` summarise it but drop the detailed eval findings. README still points at it (line 218).

## Scope
Find out why the file keeps getting emptied (likely the agent eval deleting its own work or the repo's docs), then either restore it from `dede4b7`, or fold the findings into `docs/` and update the README link.

## Acceptance
README link resolves to real content and the file stays intact after an eval run.
