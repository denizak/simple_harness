# T15 — Repo-based agent eval cases

**Status:** backlog

## Scope
Add a `repo` seed to the runner: check out a real repository at a given commit into the work dir and grade with its real test suite (for example add a flag to this harness, check with `swift test`).

## Acceptance
At least one case seeded from a checkout validates (check fails on seed, passes after the solution) and runs end to end.
