# T13 — Run both agent eval sets on a weaker model

**Status:** backlog

## Why
glm-5.3-flash passes 63/63, so both sets only act as regression tripwires. A weaker or cheaper model shows where the cases start to discriminate.

## Scope
Run `agent.json` and `agent-hard.json` with `--provider deepseek` (or similar), record pass rates, turns, tokens and cost. Exercise the failure paths that have not fired live: timeout, turn cap, kept artifacts.

## Acceptance
Results recorded in the docs, with any case that is too easy or too noisy noted.
