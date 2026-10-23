# T20 — Resume the last session at startup (`--resume`)

**Status:** done
**Commit:** 8c5fb77

## Why
Sessions autosave to `.harness/session.json` after every task (success and
failure), but resuming one requires launching the REPL and typing `/load`.
`--resume [PATH]` makes continuation a startup decision, and composed with
`--once` it becomes scriptable: `harness --resume --once "keep going"`.
No new persistence format — the flag is a startup form of `/load` and reuses
its exact restore policy (`Session.restoreModel` precedence, `selectModel`
reconfiguration). The JSONL session log stays durability-only.

## Scope
- `Sources/HarnessCore/Session.swift` — small pure, unit-tested parser:
  ```swift
  enum SessionResume: Equatable {
      case none                 // flag absent
      case last                 // --resume → Session.defaultPath
      case path(String)         // --resume PATH
      static func parse(_ arguments: [String]) -> SessionResume
  }
  ```
  Rule: the token after `--resume` is a path only if it does not start with
  `--`. Flag-only, not settable via config file/env — it is invocation
  intent, not configuration.

- `Sources/harness/Harness.swift`:
  1. Reorder startup to: `Config.resolve` → agent construction → apply
     resume → `banner(agent.config)` (banner reads the live config so it
     shows the restored model, not the pre-resume one).
  2. Applying a resume request mirrors `/load` exactly: `Session.load` →
     `messages = session.messages` → `retryAvailable = false` →
     `restoreModel(activeBaseURL:)`; non-nil result goes through
     `agent.selectModel` `{ makeChatModel(for: $0) }`, nil prints the
     existing different-endpoint warning.
  3. Failure policy — explicit intent fails closed: a missing or
     undecodable file prints the error and exits 1. Silently continuing
     fresh would let the first autosave overwrite `.harness/session.json`
     and destroy the only copy of a corrupt-but-recoverable session.
  4. `--once` composes: with `--resume`, the one-shot task starts from the
     restored transcript; exit-code semantics unchanged.

- Docs: `--help` usage line; README quickstart/slash-command section; fix
  the two stale lines that say "/save remains the way to resume a session"
  (help text for `--session-log`, README extension-exercises item 3).

## Acceptance
- Parser tests: absent / bare flag / `--resume PATH` / `--resume --once x`
  does not swallow the following flag as a path.
- Restore policy: a parsed request applied through the same helpers as
  `/load` restores the model on a matching endpoint and keeps the active
  model (with warning path) on a different endpoint
  (RuntimeConfigurationTests already cover the policy; test the wiring).
- Failed load exits 1 and performs no session write (no autosave clobber).
- Restored transcript + stub model run appends exactly one new user message
  and does not replay recorded tool calls (RecoveryTests pattern).
- Gates: `swift test`, `swift run harness --selftest`,
  `swift build -c release`, `git diff --check`.

## Out of scope
- Session listing/selection (`/sessions`), named-session management.
- Cross-process `/retry` — the T05 deferral stands; retry stays in-process.
- Refreshing the saved system message on resume (it may embed an old cwd /
  attached files — identical to `/load` today; changing it should be a
  separate task that fixes both paths consistently).
- JSONL-transcript-based resume (`--session-log` remains durability-only).
- Config-file/env equivalents of the flag.
