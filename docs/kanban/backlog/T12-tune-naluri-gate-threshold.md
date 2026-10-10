# T12 — Tune the naluri gate threshold from real prompts

**Status:** backlog

## Why
The gate threshold (0.45) is untuned. The 10 gate-safety cases in `Evals/naluri.json` are all easy and every backend scores 100%, so they say nothing about borderline requests.

## Scope
Collect real borderline prompts from actual use (do not invent them), add them as gate cases, and pick a threshold per backend from the results.

## Acceptance
Threshold chosen from data and recorded in the README or eval notes.
