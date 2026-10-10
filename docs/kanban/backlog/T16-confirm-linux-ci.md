# T16 — Confirm Linux CI on recent commits

**Status:** backlog

## Why
Linux CI has not been confirmed against commits since `ec13406`, and the eval runner is POSIX-dependent.

## Scope
Check the ubuntu CI job on `main`, fix any Swift 6 strict-concurrency or portability breakage.

## Acceptance
Green macOS and Linux CI on `main`.
