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

```bash
swift build
./.build/debug/harness                 # interactive REPL
./.build/debug/harness --selftest      # verify the tool layer (no API call)
./.build/debug/harness --once "list the files in this directory"   # one-shot
```

Slash commands inside the REPL: `/help /reset /model /tools /save /load /retry /exit`.

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

Autodetect: the first provider with a key in the environment wins, in the
order **ollama-cloud → zai → deepseek → openai** (set `--provider` to be
explicit). DeepSeek also borrows a key stored in pi's `auth.json`.
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
If pi is installed, its `~/.pi/agent/models.json` provider is borrowed as a
fallback — same trick pi itself uses for provider config. Inside the REPL,
`/models` lists what the current provider offers.

Ollama Cloud notes ([docs](https://docs.ollama.com/cloud)): model ids are the
raw tags from `https://ollama.com/api/tags` (e.g. `kimi-k2.7-code`); the
`:cloud` suffix is only for a signed-in local server. `tool_choice` is not
supported by the cloud API — the harness never sends it anyway.

Provider quirks live in one place (`LLMClient.swift`): e.g. newer OpenAI models
require `max_completion_tokens` instead of `max_tokens`.

## Testing

Two flags, two layers — and they fail for different reasons:

```bash
harness --selftest    # tool layer + pure loop math (no API call)
                      # tools, compaction boundary rules, provider resolution
harness --e2e         # the LOOP with a scripted STUB MODEL (offline, ms-fast)
                      #   …plus one LIVE round-trip against the provider
```

The e2e stub is the key idea: a scripted `ChatModel` drives the real agent
with real tools in a temp directory, forcing compaction mid-task. It proves
tool_calls parse, tools execute, results feed back, and the loop terminates —
the 90% of a harness that never needs a network. The live leg then answers
the only question the stub can't: does the request satisfy the real server?

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
- **Typed judgments (TypeSafe).** The `judge` tool calls TypeSafe's System
  One model (Jev) — answers with calibrated probabilities, not prose:
  yes/no (noul), pick-one (choice: distribution + confidence), rubric score.
  Enable with `TYPESAFE_API_KEY`. The agent reaches for it when a decision
  wants a number ("is this urgent? 0.96") instead of generated text; Jev
  answers, the agent loop still owns the workflow.
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

1. **Streaming (SSE)** — parse `data: {...}` chunks from
   `/chat/completions` with `URLSession.bytes(for:)`; print tokens as they
   arrive.
2. **Tool-approval gate** — confirm before `bash` runs; per-tool allowlists.
3. **JSONL sessions** — append one line per message instead of rewriting a
   JSON blob (pi's `session-format.md`); enables crash recovery.
4. **A second client** — implement `ChatModel` for Anthropic's native
   Messages API and compare the tool-use protocols.
5. **Sub-agents** — expose "spawn a fresh harness" as a tool.