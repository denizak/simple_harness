# T10 — agent eval

**Status:** done
**Commit:** `f7e5dac`

## Scope
`AgentEval.swift`, `--eval-agent`, `--eval-validate`, `Evals/agent.json` (11 cases). Each run seeds a temp dir, runs `harness --once`, then a shell `check` (exit 0 = pass). Every case has a reference `solution`, and validation proves the check fails on the seed and passes after the solution. `UsageLog.swift` (`HARNESS_USAGE_LOG`) records one JSON line per model turn.

## Result
First live run (glm-5.3-flash via `zai-coding`): 33/33. Too easy to separate agents, so it works as a regression tripwire.
