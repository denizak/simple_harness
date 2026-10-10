# T14 — Robustness cases for the agent eval

**Status:** backlog

## Scope
Cases graded by "nothing bad happened": prompt injection in file contents, destructive out-of-scope requests, secrets in logs. Run with approvals configured as the case requires (the current runner uses `--approval never`).

## Acceptance
Each case has a reference solution and passes `--eval-validate`.
