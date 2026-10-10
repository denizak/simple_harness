# Implemented follow-up tasks

Originally planned against baseline `c96ad42`. T1–T5 were implemented in order in that worktree; T6 was planned against `4d7ba3a` and is now implemented (`a566d93`). This document is a historical record — current status lives in "Completion status" below.

**Status: T1–T10 all implemented on `main`.** The roadmap items from README
"Where to go next" are complete; the one remaining named follow-up is the per-tool
approval allowlist (T6's deferred refinement).

## Baseline and order

`swift test` on this workstation: 23 tests, two failing tests with three failed expectations. Both failing tests assume particular API-key entries exist whenever the user's auth file exists. No live provider tests were run.

Execution order used: **T1 → T2 → T3 → T4 → T5**. T1 established a trustworthy test baseline; T2–T4 were otherwise independent. T5 built on T2's runtime-state work.

Keep the dependency-free, macOS/Linux design. Use scripted models, temporary directories, and fake credentials in tests. Do not read or modify real credentials in tests. No live API calls are required for these tasks.

## T1 — Make provider resolution tests hermetic

**Why now:** `Config.resolve(arguments:env:)` still reads the real home directory. `ProviderTests.piKeyBorrowing` and `deepseekDefault` fail here because the existence of `auth.json` does not imply that it contains DeepSeek or Z.ai API keys.

**Files:** `Sources/HarnessCore/Config.swift`, `Sources/HarnessCore/Providers.swift`, `Tests/HarnessTests/HarnessTests.swift`; update related checks in `Sources/harness/Selftest.swift` if they depend on the same assumption.

**Implementation:**
1. Introduce a Sendable snapshot of borrowed configuration: optional `PIProvider` plus a provider-name-to-API-key dictionary. Make `PIProvider` Sendable as needed.
2. Keep the production resolver entry point loading that snapshot from disk. Add a resolver overload accepting an explicit snapshot; this overload must perform no filesystem reads.
3. Refactor key selection to use the supplied snapshot rather than calling `borrowedKey()` during resolution. Keep existing precedence and DeepSeek's explicitly declared autodetect-borrowing behavior.
4. Separate parsing from file loading so malformed JSON, OAuth entries, and empty keys can be tested with in-memory data.
5. Replace the real-home-dependent tests with fake snapshots. Give all resolver tests explicit snapshots, including an empty one where appropriate.
6. Correct README statements claiming borrowed keys are exclusively opt-in: the current DeepSeek policy is an exception. This task documents existing behavior, not a policy change.

**Acceptance tests:**
- Empty environment + empty snapshot selects local Ollama.
- An explicit OpenAI environment key beats a borrowed DeepSeek key.
- Borrowed DeepSeek is autodetected when there is no environment key.
- Coding-plan credentials alone never trigger coding-plan autodetection.
- Explicit provider selection borrows only the designated entry; explicit environment key wins.
- Missing entries, OAuth entries, empty keys, and malformed input do not create credentials.
- Borrowed provider-config fallback and CLI/env override precedence remain covered.
- `swift test` passes regardless of the contents or existence of the developer's home configuration.

**Out of scope:** new providers, changing default-provider policy, accessing real secrets.

## T2 — Make model switches affect actual requests

**Why:** `/model` and same-endpoint `/load` mutate `agent.config.model`, but `OpenAICompatClient` retains its original value-type `Config`. The displayed model and saved session can therefore differ from the model sent to the API.

**Files:** `Sources/HarnessCore/Agent.swift`, `Sources/HarnessCore/Session.swift`, `Sources/harness/Harness.swift`, new `Tests/HarnessTests/RuntimeConfigurationTests.swift`.

**Implementation:**
1. Add one testable runtime reconfiguration operation in HarnessCore that replaces the agent configuration and its client together. Accept a client factory so tests can supply recording stub models; production uses `OpenAICompatClient.init(config:)`.
2. Route `/model` and the accepted model-restoration branch of `/load` through this operation. Preserve messages, agent depth, and all unrelated configuration fields.
3. Keep the existing load policy: same endpoint restores the saved model, different endpoint retains the active model, legacy sessions retain their documented behavior.
4. Ensure the refreshed client is the one used by normal turns, streaming, compaction, and spawned agents.
5. Add a comment explaining the configuration/client ownership rule to prevent future direct-mutation regressions.

**Acceptance tests:**
- After selecting model B from model A, request construction emits `model: B`, not merely a changed UI label.
- Same-endpoint session restore produces requests for the restored model.
- Different-endpoint restore retains the active endpoint, key, and model.
- A recording client verifies the refreshed client reaches compaction and delegated work.
- Saved session metadata agrees with the active request model.
- Tests remain network-free; existing stub-model injection still works.

**Out of scope:** switching providers interactively, redesigning `ChatModel`.

## T3 — Enforce tool boundaries and validate dangerous arguments

**Why:** `Agent.execute` resolves against `Tools.all`, not the advertised `availableTools`. Spawn visibility and execution guards disagree about the depth boundary. File tools ignore `ToolContext.cwd`; negative `read_file.limit` can reach `prefix` with an invalid count.

**Files:** `Sources/HarnessCore/Agent.swift`, `Sources/HarnessCore/Tools.swift`, `Sources/HarnessCore/Config.swift`, new `Tests/HarnessTests/ToolBoundaryTests.swift`.

**Decisions:** root depth is 0; `maxAgentDepth = 2` permits root → depth 1 → depth 2. At depth 2, spawning is forbidden. Depth 0 as a limit disables spawning. Absolute file paths remain permitted: cwd resolution is not a sandbox.

**Implementation:**
1. Advertise `spawn_agent` exactly when `depth < maxAgentDepth`. Keep the executor-side spawn guard consistent with that definition.
2. Resolve requested tools against `availableTools`; return a tool-result error for unavailable or invented tools without executing them. List only available tools in the error.
3. Add a shared path resolver using `ToolContext.cwd`; use it for read, write, edit, and grep. Do not change process-global cwd.
4. Validate `read_file.limit > 0`, `grep.max_matches > 0`, and positive finite shell timeouts before execution. Preserve the existing offset clamp to 1. Reject empty file paths and empty `edit_file.old_text`.
5. Return validation failures as tool-result text, leaving files unchanged.

**Acceptance tests:**
- Depth limits 0, 1, and 2 have matching advertised and executable behavior.
- A scripted model requesting a hidden spawn tool cannot start a child; it receives one result for its call ID.
- Relative file operations resolve within an explicit temporary cwd without `chdir`; absolute-path behavior still works.
- Concurrent tests using the same relative filename in different directories remain isolated.
- Zero/negative limits, invalid timeouts, and empty replacement needles return errors without crashes or writes.
- Existing successful delegation and file-tool tests remain green.

**Out of scope:** approval prompts, path confinement, general JSON Schema validation.

## T4 — Make shell execution bounded and deadlock-resistant

**Why:** `runShell` drains stdout to EOF before reading stderr. A child filling stderr can block while stdout remains open. Output is fully buffered before truncation. The watchdog targets only the shell PID, so descendants holding pipes open can outlive the deadline.

**Files:** `Sources/HarnessCore/Tools.swift`, new `Sources/HarnessCore/ShellRunner.swift`, new `Tests/HarnessTests/ShellRunnerTests.swift`; package changes only if required for portable POSIX interop.

**Implementation:**
1. Extract process launch, capture, and timeout handling into `ShellRunner`; keep `Tools.runShell` as the compatibility wrapper.
2. Drain stdout and stderr concurrently. Preserve separate stdout/stderr sections; do not promise ordering between them.
3. Retain at most 64 KiB per stream, continuing to drain and discard overflow. Report discarded byte counts. Keep the agent's existing character-based context truncation as an additional layer.
4. Launch the shell in a dedicated process group using portable POSIX spawn attributes, not a racy post-launch group assignment. Preserve the OS shell choice and `-lc` arguments.
5. Track timeout explicitly. On deadline, send SIGTERM to the owned group, then SIGKILL after 500 ms. Coordinate readers and child reaping; stop watchdog work when the run is complete and never signal the harness's group.
6. Bound the final pipe-drain wait after timeout and close remaining readers if necessary. An escaped/detached descendant must not indefinitely block the tool, though killing deliberately escaped descendants is not guaranteed.
7. Remove the duplicate `process.arguments` assignment as part of replacing the launch path.

**Acceptance tests:**
- A command writing over 1 MiB to stderr before closing stdout finishes successfully, without waiting for its timeout.
- Large stdout and stderr are drained with bounded retained output and explicit truncation counts.
- A shell waiting on a sleeping child returns within a generous timeout-plus-cleanup bound; the ordinary child process is no longer alive.
- SIGTERM-resistant commands reach the SIGKILL path; normal completion never reports a timeout.
- Nonzero exit codes, empty output, invalid cwd, and invalid UTF-8 have deterministic reports.
- Test fixtures use system shell utilities only and have external hard deadlines so a regression cannot hang CI. Run on both existing macOS/Linux CI jobs.

**Out of scope:** interactive terminals, full sandboxing, daemon supervision, user-initiated cancellation UI.

## T5 — Recover failed tasks without replaying completed tool actions

**Why:** `/retry` works only when the last message is a user message. After a successful tool execution followed by a model failure or turn-cap error, the transcript ends in a tool result and retry reports “nothing to retry.” Autosave currently runs only after success, and `--once` catches failures without a failing process exit.

**Files:** `Sources/HarnessCore/Agent.swift`, `Sources/HarnessCore/Session.swift`, `Sources/harness/Harness.swift`, new `Tests/HarnessTests/RecoveryTests.swift`; a small HarnessCore task-controller type if needed to keep CLI behavior testable.

**Implementation:**
1. Split appending a new user task from continuing the existing agent loop. Keep `run(task:messages:)` as the public convenience entry point.
2. Track whether the current task completed or failed in runtime state. `/retry` resumes only a failed task; it must not append the original user prompt again or replay recorded tool calls.
3. Give explicit retries a fresh per-run turn budget. Do not add automatic network retries or replay partially streamed output as transcript messages.
4. Attempt atomic session saving after both success and caught failure. Print an actionable warning on save failure instead of suppressing it.
5. Make task execution return a testable outcome: `--once` exits nonzero on task failure or persistence failure; interactive mode reports the error and remains usable.
6. Clear retry state after success, `/reset`, or `/load`. Persisting resumability across process restarts is deferred; this task saves failed transcripts for inspection but resumes only failures from the current process.
7. Update `/help` and README recovery behavior.

**Acceptance tests:**
- Initial model failure followed by retry retains exactly one user prompt.
- A scripted model writes a file, then fails; retry continues from the recorded tool result, and the write tool is executed exactly once.
- Turn-cap failure can be explicitly resumed without losing tool-call/result pairing.
- Successful completion, reset, and load do not leave stale retry state.
- Failed task transcripts are saved; save failures are visible.
- `--once` returns nonzero for an unreachable local endpoint and zero for a successful stub-backed controller test. No paid endpoint is used.
- An interactive failure does not terminate the REPL.

**Out of scope:** JSONL journaling, crash recovery mid-tool, exactly-once side effects across crashes.

## T6 — Tool-approval gate (implemented)

Implemented in `a566d93` (planned against `4d7ba3a`, not `c96ad42`). Builds on T3's
enforced dispatch boundary: `Agent.execute` already resolves against `availableTools`, parses
arguments, and turns every failure into exactly one tool result. This task inserts one
optional human decision between argument parsing and execution — README "Where to go
next" #2.

Landed as: `Sources/HarnessCore/Approval.swift` (pure rule, decision type, hook type,
interactive prompt), `ApprovalPolicy` in `Config` resolved from `HARNESS_APPROVAL` and
`--approval`, REPL-only hook installation in `Sources/harness/Harness.swift`, task-scoped
"always allow" state inherited by `spawn_agent` via `ToolContext`, selftest coverage in
`Sources/harness/Selftest.swift`, and `Tests/HarnessTests/ApprovalTests.swift`.

**Why now:** The pre-model `ModelGate` judges whole user *tasks* with a classifier, but
no authority stands between a model decision and a destructive tool run. `bash` can do
anything; `write_file` can overwrite. An approval gate at the single execution choke
point closes that gap with the same "errors are text" philosophy the rest of the loop
uses.

**Files:** new `Sources/HarnessCore/Approval.swift`, `Sources/HarnessCore/Agent.swift`,
`Sources/HarnessCore/Tools.swift` (ToolContext + spawn_agent inheritance only),
`Sources/harness/Harness.swift` (flag parsing + REPL hook installation),
`Sources/HarnessCore/Config.swift`, `README.md`, new
`Tests/HarnessTests/ApprovalTests.swift`.

**Decisions (the two open questions, answered):**
- *Interactive vs noninteractive:* the interactive REPL installs a real y/n/a prompt;
  `--once` never does. When a policy requires approval and no hook is installed, the
  call is **denied** (fail-closed). This is the deliberate opposite of the classifier
  gate's fail-open: an unreachable classifier is an outage, an unreachable human is
  not consent.
- *Child-agent inheritance:* the approval hook and the task-scoped "always allow" state
  travel on `ToolContext`; `spawn_agent` passes them to the sub-agent it constructs
  (next to `context.config`, which it already copies). An approval granted at depth 0
  applies at depth 1; nothing new to configure.
- *Policy levels:* `never` (default — current behavior, all existing tests unchanged),
  `dangerous` (`bash`, `write_file`, `edit_file` — the mutating/executing set;
  `grep`, `read_file`, `naluri`, `spawn_agent` are read-only or delegation), `all`.
- *Denied calls* return a tool-result error naming the tool, so the model can adapt
  (propose something else) on its next turn — exactly like T3's unavailable-tool path.
  A denial still consumes a turn; that is inherent to results-as-text.
- *Scoping:* "always allow this tool" (the `a` answer) lives in an actor created per
  top-level task. `run(task:)` resets it; `continueRun` (a `/retry` of the same task)
  keeps it — retry must not re-prompt what the user already approved.

**Implementation:**
1. Add `ApprovalPolicy` (`never | dangerous | all`) to `Config` (default `.never`),
   resolved from `HARNESS_APPROVAL` and a `--approval` flag, following the
   `HARNESS_GATE` pattern.
2. In `Approval.swift`: the pure rule `decide(policy:tool:alreadyApproved:) -> needsAsk?`
   (unit-testable without I/O), an `ApprovalDecision` (`approve | approveAlways | deny`),
   a `Sendable` hook typealias `@Sendable (String, String) async -> ApprovalDecision`
   (tool name + one-line argument summary), and the interactive stdin prompt.
3. `Agent` gains the hook + shared state; `ToolContext` carries them so `spawn_agent`
   forwards both. Add the ownership comment in the style of T2's reconfigure comment:
   the *policy* lives in Config, the *decider* is injected, and a nil decider with a
   demanding policy must deny, never execute.
4. In `Agent.execute`, after successful argument parsing and before `tool.run`: consult
   the rule, ask the hook if needed, record `approveAlways`. A deny returns the
   tool-result error without executing and without mutating any file. Malformed
   arguments still fail as parse errors — never prompt about an unparseable call.
5. `Harness.swift`: parse the flag, install the interactive hook only in REPL mode,
   print a one-line notice when a policy is active. `/help` and README updated in the
   same commit, including the fail-open (gate) vs fail-closed (approval) contrast.
6. Extend `--selftest` with the pure rule and a scripted deny-through-a-stub-loop case
   so the feature is verifiable offline, like the rest of the selftest.

**Acceptance tests:**
- Policy `never` changes nothing: the existing 43-test suite passes unmodified.
- `dangerous` prompts for `bash`/`write_file`/`edit_file` and never for
  `grep`/`read_file`/`naluri`.
- A scripted deny produces exactly one tool result per call ID and the target file in a
  temporary directory is untouched (proved by content, not by mocking).
- Denial text names the tool and the loop continues: a scripted model that is denied
  once and succeeds with an alternative completes the task.
- `approveAlways` suppresses the second prompt within one task; a new task prompts
  again; a `/retry` of the same task does not re-prompt.
- Nil hook + `dangerous` denies without executing (fail-closed), stated opposite of the
  fail-open gate, with a test pinning the difference.
- A sub-agent's dangerous call consults the shared hook; an "always" from the parent
  covers the child; the child cannot silently widen its own policy.
- All tests network-free (stub models + scripted hooks), no TTY required; the prompt
  implementation itself is exercised only by the selftest reading scripted stdin.

**Out of scope:** per-argument or per-command allowlists ("allow `git status`, deny
`rm`"), path confinement, diff previews for `edit_file`, remote/mobile approval UIs,
persisting approvals across restarts, and wiring the naluri classifier in as an
auto-approver (a natural follow-up: classifier *suggests*, human decides).

## Completion status

T1–T6 all implemented with offline tests, plus post-T6 hardening (`@`-file completion:
`e27aeef`, `4cce27e`, `b7d7bc0`; ShellRunner pipe-drain/EINTR: `13f63bc`, `f004251`),
T6.5 (JSONL session log, `e666889`), T7 (Anthropic-native client, `371322a`), and T7a
(OpenRouter provider profile, `ec13406`), T8 (naluri, `73dc73c`) and T9 (naluri eval, `4bcdadf`). Latest macOS verification:
`swift test` passed (96 tests), `swift run harness --selftest` passed, `swift build -c
release` passed, `git diff --check` clean. History through `ec13406` is pushed to
`origin/main`. Linux CI has not yet been confirmed against recent commits.

## Shared completion gate

For each task:

```sh
swift test
swift run harness --selftest
swift build -c release
git diff --check
```

Confirm macOS and Linux CI before merging portability-sensitive changes. Do not run `--e2e` as a routine gate: it includes live provider calls. Update affected documentation in the same commit and report any pre-existing failure separately.

## After these fixes

Roadmap status: streaming (SSE), JSONL sessions, an Anthropic-native client (T7), and
T7a OpenRouter are all implemented (see below). The remaining candidate to pick next is
**per-tool approval allowlists** — the explicitly named T6 follow-up (README "Where to
go next" #2).

## T6.5 — JSONL session log (implemented)

README "Where to go next" #3. Landed as `Sources/HarnessCore/JSONLSession.swift`
(`SessionEvent`, `JSONLSessionLog`), `Config.sessionLog` resolved from `--session-log`
/ `HARNESS_SESSION_LOG` (with `--no-session-log` override), journal hooks in
`Agent.run`/`continueRun` (user, assistant, tool-result appends) plus
`Compaction.compactIfNeeded(_:config:model:journal:)`, and
`Tests/HarnessTests/JSONLSessionTests.swift` (6 tests).

**Design:** an append-only *event* stream, not a message mirror. One JSON object per
line: `{"kind":"append", "message": …}` or `{"kind":"replace", "messages":[…]}`.
Compaction rewrites the in-memory history wholesale, so it journals a `replace` the
loader replays as "history is now exactly this" — no watermark bookkeeping. Writes go
through a serial queue onto an `O_APPEND` fd and `fsync` per line, so parent and
spawned sub-agents share one log safely and a crash loses at most the in-flight turn.
`load` skips corrupt lines (a torn tail is normal after a crash) and returns empty for
a missing file.

**Scope line:** this covers *durability* only. `/save` + `/load` remain the resume
mechanism: resuming needs model/endpoint state (`Session.restoreModel`) that a
transcript does not carry, and a restored log is never re-saved as a session blob.

**Test that caught a real bug:** the replace-event test opens two writers on one path;
the first draft used `FileHandle.seekToEndOfFile`, whose offset is fixed at open time —
the second writer clobbered the first one's line (restored history came back empty).
Switched to raw `open(O_WRONLY|O_APPEND)` so the kernel re-anchors every write to the
current end of file.

**Default is OFF:** the agent's `log` is lazily built from `config.sessionLog`; nil
config means zero logging, exactly the pre-T6.5 behavior. 70 tests pass (64 prior +
6 new); selftest and `--session-log` smoke run verified.

## T7 — Anthropic-native client (implemented, `371322a`)

README "Where to go next" #4, as planned in the previous revision of this document.

Landed as: `Sources/HarnessCore/AnthropicClient.swift` (`AnthropicClient`: non-streaming
`complete` + streaming `stream` conforming to `ChatModel`; `AnthropicSSEAssembler` with
typed-event grammar; `StaticAnthropicModels` for `/models`), provider catalog entry
`anthropic` (base URL `https://api.anthropic.com/v1`, key from `ANTHROPIC_API_KEY`,
borrowing policy consistent with T1, `ANTHROPIC_BASE_URL` + explicit `--anthropic-base-url`
override for local proxies) in `Config.swift`/`Providers.swift`, CLI flag in
`Sources/harness/Harness.swift`, request/response/streaming mappings offline-covered by
`Tests/HarnessTests/AnthropicClientTests.swift` (10 network-free tests via a local HTTP
stub + in-memory JSON), and a new README section "Two tool protocols (OpenAI vs
Anthropic)" with the full mapping table.

Design points: `system` hoisted to the top-level parameter; `tool_calls` → `tool_use`
blocks and `role: "tool"` results → `tool_result` blocks inside the next `user` message;
`arguments` string-encoded ↔ `input` structured; `stop_reason` mapped to the neutral
`stop`/`tool_calls`/`length` three; streaming is a typed event grammar
(`content_block_start` / `input_json_delta` / `message_delta`) rather than delta
fragments, with partial-JSON reassembly for fragmented tool arguments. The neutral
`Message`/`AssistantTurn` wire format is unchanged — the agent loop is dialect-blind.

**Comparison summary (see README table for detail):** same conceptual tool protocol,
their wire encodings differ — OpenAI encodes tool arguments as strings and pairs results by
`tool_call_id` in separate messages; Anthropic encodes them as structured JSON blocks
and pairs by block order within one user message. Anthropic's streaming grammar is
typed per content block; OpenAI's is per-delta. Nothing in the loop changes; only the
client conformer + `SSEAssembler` differ, which is exactly what the `ChatModel`
abstraction was supposed to buy.

## T7a — OpenRouter provider profile (implemented)

Small companion to T7: OpenRouter speaks the standard OpenAI Chat Completions
dialect, so it needed only a `ProviderProfile` ("openrouter",
`https://openrouter.ai/v1`, `OPENROUTER_API_KEY`, `vendor/model` ids such as
`anthropic/claude-sonnet-4.5`, `keyResolution: .envOnly` — no pi borrowing). It was
appended to `autodetectOrder` after `openai` so a present env key autodetects.
Covered by a ProviderTests case (not in autodetect without a key; env-key autodetect;
explicit `--provider openrouter` yields no credential). README provider table and
autodetect order updated.

## T8 — naluri: vendor-neutral typed instinct (implemented, `73dc73c`)

The `judge` tool was tied to one vendor (TypeSafe's Jev). It is now **naluri**
(Indonesian for instinct — Kahneman's System One): fast, typed gut-calls with
probabilities, as the counterpart to the deliberate chat loop.

- **Split:** `Naluri.swift` holds the vendor-neutral parts (`NaluriQuestion`,
  `NaluriBackend`, `NaluriFormat.render`, `Config.naluriBackend` selection);
  `TypeSafe.swift` is only the Jev HTTP client + `TypeSafeBackend`;
  `NaluriTool.swift` is the `naluri` tool (renamed from `judge` — update any
  allowlists referring to the old name); `Gate.swift` goes through the backend.
- **ChatNaluri** (`ChatNaluri.swift`): cheap chat models (deepseek, zai) as a
  backend. One request per question, answer constrained to one token (yes/no,
  option letter, level digit), probabilities from `top_logprobs` normalised over
  the allowed tokens. No logprobs → one-hot, flagged `uncalibrated`. Choice
  questions are limited to 2–26 options, score to 2–10 levels on this backend.
- **Config:** `HARNESS_NALURI` / `--naluri` / `"naluri"`, and
  `HARNESS_NALURI_MODEL` / `--naluri-model` / `"naluriModel"`. Vendor key names
  (`TYPESAFE_API_KEY`, `typesafeApiKey`) are unchanged.
- **Tests:** ChatNaluriTests (distribution, prompts, answer shape, backend
  selection); pure, no network.
- **Verified live (via T9):** DeepSeek returns `top_logprobs` and works as
  designed. z.ai's API has no logprobs at all, so GLM answers are always the
  one-hot `uncalibrated` fallback; `glm-5.3-flash` also cannot disable
  thinking. The pay-as-you-go `zai` endpoint had no balance for it (HTTP 429,
  code 1113); the coding-plan profile `zai-coding` works.
- **Follow-up fixes:** provider env key wins over the active config's `apiKey`;
  per-provider `naluriModel` / `naluriMaxTokens` live in the catalog; an
  out-of-balance 429 is not retried; empty content with `finish_reason: length`
  retries once with a larger budget.

## T9 — naluri eval (implemented)

First slice of the eval roadmap: compare naluri backends on 40 drafted, labelled
cases (`Evals/naluri.json`: 12 urgency, 10 gate-safety, 10 routing, 8 severity).
`NaluriEval.swift` (library: case model, pure scoring, runner, table) +
`EvalCommand.swift` (`--eval-naluri` CLI). Metrics: accuracy (overall and per
group), Brier score, overconfidence (mean confidence − accuracy), confidence
when wrong, uncalibrated count, latency, tokens, estimated cost. Score cases map
the backend's legend numbering (0- or 1-based) onto the 0-based expectation.
Spend cap `--eval-budget` (default $1) on *estimated* cost with assumed,
conservative prices. Offline tests cover the case file's validity and the
scoring. Live runs: see the findings below.

**Caveats:** the 40 cases are synthetic and drafted by the assistant — at this size
a difference under ~15 points between backends is noise; replace or extend them
with real prompts (especially the gate-safety group). The gate threshold needs
tuning per backend from these results.

**Next:** the agent eval — built as T10.

**Eval findings (first live runs, 40 cases):** Jev and deepseek-flash 40/40, glm-5.3-flash
38/39 graded. The set is too easy to rank accuracy; calibration is what separates the
backends — Jev gives graded probabilities (20/40 below 0.99, min 0.64), deepseek-flash
is saturated (all ≥ 0.99), z.ai has no logprobs at all (picks only, flagged
uncalibrated). Gate stays on Jev. glm-5.3-flash cannot disable thinking, so a 4-token
cap returned empty content on one case; fixed with `ProviderProfile.naluriMaxTokens`
(1024 for the GLM profiles) plus a one-shot 16× retry when content is empty and
finish_reason is `length`.

**Harder set (70 cases):** 30 deliberately ambiguous cases added (10 urgency with
misleading wording, 10 routing tickets that touch two teams, 10 severities on the line
between two levels), marked `"difficulty": "hard"`. Ambiguous choice/score cases carry
`alsoAccept` (other defensible answers, graded correct). The table now splits easy vs
hard accuracy and mean confidence — a backend whose confidence does not drop on hard
cases is giving picks, not probabilities. No hard cases were drafted for the gate-safety
group: borderline requests there should come from real prompts, not invented ones.

**Eval findings (70 cases, 40 easy + 30 hard; run `2026-10-10`):** all three backends
96% overall and 90% on the hard cases (3 misses each of 30 — not enough to rank accuracy).
Calibration is what differs:

| Backend | Hard-case confidence | Confidence when wrong |
|---|---|---|
| Jev | 0.80 (0.97 on easy) | 0.53 |
| deepseek-flash | 1.00 | 1.00 |
| glm-5.3-flash | 1.00 (uncalibrated one-hot) | 1.00 |

Jev's confidence falls on ambiguous cases and its mistakes sit near 0.5, so a threshold or
"escalate to a human" rule can act on it; DeepSeek and GLM are confidently wrong, giving
nothing to threshold. Conclusions: keep the gate on Jev; use the chat backends only where an
occasional confident error is acceptable (routing, severity picks); GLM costs more than
DeepSeek in latency (~1.3 s vs ~0.75 s) and spend for no gain here. Estimated spend for the
full 70 × 3 run: ~$0.04 (assumed prices, not billed).

**Reading the numbers:** Brier is only computed for yes/no and choice questions, so it is
not comparable across backends — GLM's low 0.038 reflects having no misses on those types,
not better probabilities. Most misses are cases where the label is arguable (e.g. dates in US
format for European users: cosmetic vs major; "not urgent, but staging password posted in a
public channel"), so a miss says little about the model. The gate group (10 cases) is all
easy and all backends scored 100%, so **the gate threshold (0.45) remains untuned** — it needs
borderline prompts from real use.

## T10 — agent eval (implemented, `f7e5dac`)

Grades outcomes, not prose: `AgentEval.swift` (library: case model, seeding, validation,
runner, summary, table) + `AgentEvalCommand.swift` (`--eval-agent`, `--eval-validate`) +
`Evals/agent.json` (11 cases). Each run seeds a temp dir, spawns `harness --once` there
(subprocess, so the real binary and tools are exercised and the process-global cwd is a
non-issue), then runs the case's shell `check` (exit 0 = pass).

- **Core change:** `UsageLog.swift` + `Config.usageLog` / `HARNESS_USAGE_LOG` — one JSON
  line per model turn (`depth`, `prompt`, `completion`, `finish`), written from
  `Agent.continueRun` and shared with sub-agents via the config. Previously usage was only
  printed. Opt-in; a write failure is silent.
- **Soundness without a model:** every case carries a reference `solution`. `validate`
  (CLI `--eval-validate`, and a `swift test`) proves the check fails on the seed and passes
  after the solution, so a pass can't be vacuous and a fail isn't a broken check.
- **Metrics per case over N runs:** passes/runs, mean turns, tool calls, tokens, seconds;
  per-group pass rate; timeouts vs harness-error/turn-cap endings; estimated cost against
  `--eval-budget` (assumed prices in `AgentEvalPricing`, no run starts past the cap).
  Failed runs keep work dir + transcript + stdout.
- **Safety:** approvals are off (`--approval never`) and `bash` is real. The temp dir is a
  start point, not a sandbox; the CLI prints a warning. Run only reviewed cases, ideally in
  a container.
- **Tests (offline):** all shipped cases validate; validation catches a vacuous and an
  unsatisfiable check; shell-report parsing/quoting; usage-log append/totals; summary and
  pricing. The runner's plumbing was first smoke-tested against a dead local endpoint (spawn,
  artifacts kept, report written, zero spend), then run live (below).

**Caveats:** 11 cases × a few runs is small — pass-rate differences under ~20 points are
noise. Cases are synthetic and use python3 + POSIX tools, so they need both on `PATH`.
`--approval never` means the eval says nothing about approval-gate behaviour (covered by
the stub-model tests). A forwarded config's `apiKey` still overrides provider env keys (the
existing precedence), so pass `--eval-no-config` plus `--provider X` and export the key if
results look like auth errors.

**First live run (glm-5.3-flash via `zai-coding`, 11 cases × 3 runs):** 33/33 passed, 2–6 turns
(~4.5 mean), ~25 s per run, 3k–13k tokens per run, est. $0.17 at assumed prices. The
usage log, subprocess runner and report all work against a real provider. The set is too
easy to separate agents — same ceiling the first naluri set hit — so for now it is a
regression tripwire for the harness (a drop below 100% means a change broke something),
not a capability measure. The failure paths (timeout, turn cap, kept artifacts) have not
fired live. **Next:** harder cases — hidden stricter checks (so hardcoding the visible
answer fails), misleading symptoms, larger search with decoys, underspecified tasks, long
tasks that trigger compaction, a `spawn_agent` case — plus a run against a second model.
