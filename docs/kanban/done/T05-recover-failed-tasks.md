# T5 — Recover failed tasks without replaying completed tool actions

**Status:** done

## Why
Re-running a failed task replayed tool calls that had already succeeded.

## Scope
Recovery that continues from recorded tool results instead of repeating them (`Agent.continueRun`).

## Acceptance
A scripted-model test shows a resumed task does not re-execute completed tool calls.
