# simple_harness

A minimal coding-agent harness in **Swift** — written from scratch (~1200 lines,
zero dependencies) to understand how harnesses like [pi](https://pi.dev),
Claude Code, or aider actually work. Every moving part is readable: the HTTP
client, the tool executor, the loop.

> An *agent harness* is the runtime around an LLM: it sends the conversation to
> a model, offers it tools, executes the tool calls the model *requests*, feeds
> results back, and repeats until the model answers in plain text. That's it.

## The loop (the whole idea)

```
 you › "create hello.txt and verify it"
          │
          ▼
 ┌───────────────── agent loop (Agent.swift) ─────────────────┐
 │                                                            │
 │   messages ──▶ MODEL (LLMClient.swift) ──▶ AssistantTurn   │
 │      ▲                                        │            │
 │      │                              tool_calls? ── no ──▶ print text, done
 │      │                                        │           │
 │      │                                       yes          │
 │      │                                        ▼           │
 │      └── tool results ◀── TOOLS (Tools.swift)              │
 └────────────────────────────────────────────────────────────┘
```

The single most important invariant: **the model never executes anything
itself.** It only emits *requests* (`tool_calls`). The harness executes them
and reports back. The model can be wrong; the tools are the source of truth.
That boundary is what makes the loop safe and debuggable.

## Files (read in this order)

| File | Role | Learning focus |
|---|---|---|
| `Types.swift` | Wire format: `Message`, `ToolCall`, `AssistantTurn`, `ToolSpec` | The message protocol is the heart of every harness |
| `JSONValue.swift` | Dynamic JSON type for model-generated tool arguments | Why you need "any JSON" in Swift |
| `LLMClient.swift` | `ChatModel` protocol + OpenAI-compatible HTTP client | One protocol, any provider |
| `Config.swift` | Provider catalog + resolution order | How harnesses think about "providers" |
| `Tools.swift` | `bash`, `grep`, `read_file`, `write_file`, `edit_file` | Tools are (name, schema, executor) |
| `Agent.swift` | **THE LOOP** | Start here. Comments explain every step |
| `Compaction.swift` | Summarizes old turns when the transcript grows too big | The only safe cut points are non-tool-result messages |
| `Session.swift` | JSON session persistence (autosaved per task) | Session == replayable API request |
| `Selftest.swift` | `--selftest`: tool layer without any API call | Test what's testable |
| `Harness.swift` | REPL: slash commands, `--once`, banner | The skin around the loop |

Because `Message` mirrors the API's JSON exactly, `.harness/session.json` is
literally the request body the model saw — open it after a run and read the
whole conversation: tool calls, tool results, everything.

## Quickstart

On Linux, `./setup-linux.sh` installs everything needed (Swift 6.2 toolchain
via swiftly plus the system libraries Foundation links against) and verifies
with a build + selftest. `--check` only reports what's missing.

```bash
swift build
./.build/debug/harness                 # interactive REPL
./.build/debug/harness --selftest      # verify the tool layer (no API call)
./.build/debug/harness --once "list the files in this directory"   # one-shot
```

Slash commands inside the REPL: `/help /reset /model /tools /save /load /retry /exit`.
`/retry` is available after a model/API or turn-cap failure and continues from
the saved-in-memory transcript; it does not append a duplicate user prompt or
re-execute tool calls that already have results. Failed transcripts are
autosaved for inspection. `--once` exits nonzero when the task or session save
fails.

## Install

SwiftPM has no `swift install` command — an executable is just a file under
`.build/<config>/`. Installing means: build in release mode, copy the binary
onto your `PATH`. `make` wraps that:

```bash
make install          # optimized build → ~/.local/bin/harness
harness --version     # simple_harness 0.2.0
make uninstall
make test             # tool-layer selftest (debug build, no API calls)
```

`~/.local/bin` must exist on your `PATH`; elsewhere:
`sudo make install PREFIX=/usr/local/bin`. The Makefile comments explain each
target — read it, it's 40 lines.

## Providers

All providers speak the OpenAI Chat Completions dialect — one client covers all.

| Provider | How to enable | Default model |
|---|---|---|
| `ollama` (default) | local endpoint `http://127.0.0.1:11434/v1` | `glm-5.3-flash:cloud` |
| `ollama-cloud` | `export OLLAMA_API_KEY=…` ([get a key](https://ollama.com/settings/keys)) | `kimi-k2.7-code` |
| `deepseek` | `export DEEPSEEK_API_KEY=…` — or borrow the key pi has stored in `~/.pi/agent/auth.json` automatically | `deepseek-flash` |
| `openai` (ChatGPT) | `export OPENAI_API_KEY=sk-…` | `gpt-4o-mini` |
| `zai` (Z.ai / Zhipu GLM) | `export ZAI_API_KEY=…` | `glm-4.6` |
| `openrouter` | `export OPENROUTER_API_KEY=…` — 100+ models behind one key; model ids are `vendor/model` strings | `anthropic/claude-sonnet-4.5` |

Autodetect: the first provider with a key in the environment wins, in the
order **ollama-cloud → zai → deepseek → openai → openrouter** (set `--provider` to be
explicit). pi-stored keys (`auth.json`) are borrowed for named providers —
`--provider deepseek` / `zai-coding-cn` work with zero setup. DeepSeek is the
one profile that also permits a borrowed key to satisfy autodetection; explicit
environment keys always outrank borrowed keys.
Every value is overridable:

```bash
export OPENAI_API_KEY=sk-...
./.build/debug/harness --provider openai --model gpt-4o
export OLLAMA_API_KEY=...
./.build/debug/harness --provider ollama-cloud --model glm-5.3
./.build/debug/harness --base-url https://api.z.ai/api/coding/paas/v4 --api-key KEY --model glm-4.6
```

Environment overrides: `HARNESS_BASE_URL`, `HARNESS_API_KEY`, `HARNESS_MODEL`,
`HARNESS_PROVIDER`, `HARNESS_COMPACT_BYTES`, `HARNESS_COMPACT_KEEP_TAIL`.
A JSON config file (`--config PATH`, `HARNESS_CONFIG`, or by default
`.simple.h.conf` in the working directory) can hold the same values — `provider`, `baseURL`,
`apiKey`, `model`, `maxTurns`, `streaming`, `reasoningEffort`, `gate`,
`gateThreshold`, `typesafeApiKey`, `naluri`, `naluriModel`, `approval`, … as a top-level JSON object. Precedence:
flags > environment > config file > defaults.
If pi is installed, its `~/.pi/agent/models.json` provider is borrowed as a
fallback — same trick pi itself uses for provider config. Inside the REPL,
`/models` lists what the current provider offers. Typing `@` in the prompt
lists files under the working directory and live-filters them as you type
(prefix on filename or path; Tab completes the common prefix, Ctrl-U clears
the line).

### GLM Coding Plan (Z.ai)

The coding plan has its own endpoints, separate from the standard platform
API ([quick-start](https://docs.z.ai/devpack/quick-start)). Both profiles are
**opt-in** via `--provider` — a plan's quota is never used by accident, and
keys may be borrowed from pi's stored auth:

| Provider | Endpoint | Key source |
| --- | --- | --- |
| `zai-coding` | `https://api.z.ai/api/coding/paas/v4` | `ZAI_CODING_API_KEY`, or borrows pi's `zai` key |
| `zai-coding-cn` | `https://open.bigmodel.cn/api/coding/paas/v4` | `ZAI_CODING_CN_API_KEY`, or borrows pi's `zai-coding-cn` key |

On a machine where pi holds a `zai-coding-cn` api_key:
`harness --provider zai-coding-cn` works with zero setup.

Ollama Cloud notes ([docs](https://docs.ollama.com/cloud)): model ids are the
raw tags from `https://ollama.com/api/tags` (e.g. `kimi-k2.7-code`); the
`:cloud` suffix is only for a signed-in local server. `tool_choice` is not
supported by the cloud API — the harness never sends it anyway.

Provider quirks live in one place (`LLMClient.swift`):
- newer OpenAI models require `max_completion_tokens` instead of `max_tokens`;
- `stream_options` only goes to Ollama-family endpoints (some gateways
  validate strictly);
- **tools + reasoning conflicts self-heal**: when a provider answers 400 with
  "reasoning_effort is not supported … set reasoning_effort to 'none'"
  (seen on gpt-5.6-luna), the client retries once with `reasoning_effort:
  "none"` — the server's own remedy. Set your own level with
  `HARNESS_REASONING=high` or `--reasoning EFFORT`.

## Testing

Three layers, three entry points — and they fail for different reasons:

```bash
swift test            # the CI entry point: swift-testing suite (always rebuilds
                      # — no stale-binary trap), runs tests in PARALLEL
harness --selftest    # the same tool layer + pure loop math as a CLI flag
harness --e2e         # the LOOP with a scripted STUB MODEL (offline, ms-fast)
                      #   …plus LIVE legs: provider round-trip + naluri
```

The e2e stub is the key idea: a scripted `ChatModel` drives the real agent
with real tools in a temp directory, forcing compaction mid-task. It proves
tool_calls parse, tools execute, results feed back, and the loop terminates —
the 90% of a harness that never needs a network. The live legs then answer
the only question the stub can't: does the request satisfy the real server?

`swift test` needs a real SwiftPM test target — and that's also why testable
logic lives in Sources/harness beside the thin `@main` entry: executables can
be reached from tests only via `@testable import`.

## Design notes (what pi does, and why)

- **Tools report errors as text, not throws.** A failed `edit_file` comes back
  as "old_text appears 3 times…" so the model can read it and adapt. Only
  *infrastructure* failures (API down, turn cap) throw up to the REPL.
- **Streaming (SSE).** The loop requests `"stream": true` and prints visible
  text as it arrives; the response is a stream of `data: {chunk}` lines ending
  with `data: [DONE]`. The hard part is that **tool_calls arrive as delta
  fragments keyed by `index`** — the first carries id + name, later ones append
  to `arguments` — which `SSEAssembler` stitches back into a full turn. That
  assembler is a pure struct, so `--selftest` unit-tests it with canned chunks.
  Disable with `HARNESS_STREAMING=0`.
- **Naluri (typed instinct).** *Naluri* is Indonesian for instinct — the
  System One of Kahneman's pair, as opposed to the chat loop's deliberate System
  Two. The `naluri` tool answers typed questions about a text with
  probabilities, not prose: yes/no (noul), pick-one (choice: distribution +
  confidence), rubric score. The agent reaches for it when a decision wants a
  number ("is this urgent? 0.96") instead of generated text; naluri answers,
  the agent loop still owns the workflow. The pre-model `--gate` uses it too.
  Two interchangeable backends (`NaluriBackend`), same answer shape:
  - **TypeSafe (Jev)** — the default when `TYPESAFE_API_KEY` is set; calibrated
    probabilities from a purpose-built model.
  - **Chat model** (`ChatNaluri`) — a cheap flash-tier model via
    `HARNESS_NALURI=deepseek|zai` (or `--naluri`, or `"naluri"` in the config
    file) and that provider's key. Each question is one tiny request limited to
    a single answer token; the probability comes from the server's `logprobs`
    normalised over the allowed tokens. Default models: `deepseek-flash`,
    `glm-5.3-flash` (override: `HARNESS_NALURI_MODEL` / `--naluri-model`). If a
    provider returns no logprobs the answer is a one-hot pick, marked
    `[uncalibrated]`. The gate threshold means different things per model —
    re-tune `--gate-threshold` when switching backend.
- **Naluri eval.** `harness --eval-naluri [typesafe,deepseek,zai]` runs the
  labelled cases in `Evals/naluri.json` (urgency, gate safety, routing,
  severity) against each backend and prints accuracy, Brier score,
  overconfidence, latency and estimated cost; per-case results go to
  `Evals/results/` (git-ignored). It is **live** (real quota), so it is never
  part of `swift test`. Spend is capped: `--eval-budget USD` (default 1.00)
  stops issuing calls once the *estimated* cost — token usage × assumed prices
  in `NaluriEvalPricing`, not billing data — reaches the cap. `--eval-limit N`
  gives a cheap smoke run. Backends without credentials are skipped.
- **Sub-agents (orchestration).** A `spawn_agent` tool: the model delegates a
  self-contained subtask to a fresh agent (same provider and tools, empty
  conversation, same cwd) and gets back only the final report — bulk work
  burns the sub-agent's context, not the parent's. Guardrails: a depth cap
  (`maxAgentDepth`, default 2 — at the cap the tool disappears entirely) and
  failures reported as text so the parent can adapt. Watch an e2e run:
  the sub-agent's own tool calls stream right under the parent's.
- **Turn cap + output truncation.** `maxTurns` (25) stops runaway loops;
  tool output is truncated (20k chars) before it enters context — a 50 MB build
  log is not context, it's a bill.
- **Context compaction.** Before every model call the transcript's byte
  estimate is checked (`compactAboveBytes`, default 100k ≈ 25k tokens). Past
  the threshold, the older portion is summarized by the model into one
  message and the recent tail is kept verbatim. The tail may start anywhere
  EXCEPT on a tool result — an orphaned result (whose `tool_call` was
  summarized away) is rejected by the API. Compaction is best-effort: a
  failed summary never breaks the task. Try it:
  `HARNESS_COMPACT_BYTES=1600 HARNESS_COMPACT_KEEP_TAIL=4 harness --once "…"`
  → look for the `🧹 compacted …` line.
- **Watchdog on `bash`.** Commands run detached; after the deadline the child
  is `terminate()`d, then SIGKILL. Reading pipes to EOF *before*
  `waitUntilExit` avoids the classic pipe-buffer deadlock.
- **`edit_file` requires uniqueness.** Exact-match replacement that refuses
  ambiguous matches — this is what makes model edits safe to apply.

## Where to go next (exercises)

1. **Streaming (SSE)** (done — `OpenAICompatClient.stream` + `SSEAssembler` in
   `Sources/HarnessCore/LLMClient.swift`, wired into the agent turn loop) —
   parse `data: {...}` chunks from `/chat/completions` with
   `URLSession.bytes(for:)`, print tokens as they arrive, reassemble
   delta-fragmented tool calls.
2. **Tool-approval gate** (done — see `Sources/HarnessCore/Approval.swift`;
   `--approval` / `HARNESS_APPROVAL`) — confirm before `bash` runs; per-tool
   allowlists are the natural follow-up.
3. **JSONL sessions** (done — `Sources/HarnessCore/JSONLSession.swift`; opt in
   with `--session-log PATH`) — append one line per message instead of
   rewriting a JSON blob (pi's `session-format.md`); the log is fsync'd per
   line and compaction journals a `replace` event, so a crash loses at most
   the in-flight turn. `/save` + `/load` still own resuming (model/endpoint
   state is not part of a transcript).
4. **A second client** (done — `AnthropicClient` in
   `Sources/HarnessCore/AnthropicClient.swift`; `anthropic` provider in the catalog,
   `ANTHROPIC_API_KEY`, streaming + `/models`) — the native Messages API client; see
   "Two tool protocols" below.
5. **Sub-agents** (done — `spawn_agent` in `Sources/HarnessCore/Tools.swift`,
   depth-limited per T3 and approval-aware per T6) — expose "spawn a fresh
   harness" as a tool.

## Two tool protocols (OpenAI vs Anthropic)

`Agent.swift` consumes the same neutral `Message`/`ToolCall`/`AssistantTurn` wire
format from both clients — the loop doesn't know which dialect produced it. The
conformers translate:

| Concept | OpenAI `/chat/completions` | Anthropic `/v1/messages` |
|---|---|---|
| System prompt | A system `role` message (hoisted client-side) | Top-level `system` parameter, not a message |
| Tool spec | `{"type":"function","function":{"parameters"}}` | `{"name","description","input_schema"}` |
| Model calls tool | Assistant `tool_calls` array + empty content | `tool_use` content block (`id`,`name`,`input`) |
| Tool result | `role: "tool"` message + `tool_call_id` | `tool_result` block inside the next `user` message |
| Arguments | String-encoded JSON (`arguments`) | Structured JSON (`input`) — re-encoded for the neutral format |
| Finish reason | `finish_reason`: `stop`/`tool_calls`/`length` | `stop_reason`: `end_turn`/`tool_use`/`max_tokens` — mapped to the same three |
| Streaming | `data: {...}` with `delta.tool_calls` index fragments | Typed events: `content_block_start`, `input_json_delta`, `message_delta` |
| Usage | `usage.prompt/completion_tokens` | `usage.input/output_tokens` (per-message + `message_delta`) |

Auth differs too: OpenAI uses `Authorization: Bearer`, Anthropic uses `x-api-key` +
`anthropic-version`. See `Sources/HarnessCore/AnthropicClient.swift` for the full
mapping, and `Selftest.anthropicChecks()` for an offline tour of it.