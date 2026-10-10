# T10a — Agent eval, harder set and hardening

**Status:** done
**Commits:** `f6c917d` (hard set), `3b8ba87` (stop on setup failures), `308c994` (keep run evidence out of the agent's reach)

## Scope
`Evals/agent-hard.json`: 10 cases with hidden checks, required tools, forced compaction, and a `spawn_agent` case. The runner stops on setup failures instead of printing a misleading 0%, stores bookkeeping in a sibling tree, and flags runs that lose every seed file.

## Result
30/30 (63/63 with the easy set) on glm-5.3-flash. Compaction fired once in each recall run; `spawn_agent` was called three times in each delegate run. A DeepSeek run once deleted its own work tree and the runner's meta dir, which motivated the evidence-isolation fix.
