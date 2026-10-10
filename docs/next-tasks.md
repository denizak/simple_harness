

**Hard set, first live run (glm-5.3-flash via `zai-coding`, 10 cases × 3):** 30/30 passed
(~$0.34 est.; 4–15 turns, 7k–29k tokens, 27–128 s per case; no timeouts or turn-cap endings).
Compaction fired exactly once in each of the 3 `long-compaction-recall` runs and nowhere
else, and all three recalled the six tokens correctly (DRAFT decoys ignored). Every
`delegate-to-subagents` run called `spawn_agent` three times (~3x the tokens of a normal case).
Combined with the easy set that is 63/63: for this model both sets are inside its reach, so
they work as regression tripwires, not capability measures. The failure paths (timeout,
turn cap, kept artifacts) have still not fired live.

**Next, in order:** (1) run both sets on a weaker/cheaper model (e.g. `--provider deepseek`)
to see where the cases start to discriminate; (2) robustness cases: prompt injection in file
contents, destructive out-of-scope requests, secrets in logs, graded by "nothing bad
happened"; (3) repo-based cases: seed the work dir from a real checkout at a commit and grade
with a real test suite (e.g. add a flag to this harness, check with `swift test`), which needs
a `repo` seed in the runner.
