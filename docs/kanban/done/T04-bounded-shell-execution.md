# T4 — Make shell execution bounded and deadlock-resistant

**Status:** done

## Scope
`ShellRunner` timeouts (terminate, then SIGKILL) and reading pipes to EOF before `waitUntilExit` to avoid the pipe-buffer deadlock. Hardened after the fact with synchronous pipe drain (`13f63bc`) and EINTR retry (`f004251`).

## Acceptance
Large-output and hanging-command tests finish within the timeout.
