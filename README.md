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
| `Tools.swift` | `bash`, `read_file`, `write_file`, `edit_file` | Tools are (name, schema, executor) |
| `Agent.swift` | **THE LOOP** | Start here. Comments explain every step |
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

## Providers

All providers speak the OpenAI Chat Completions dialect — one client covers all.

| Provider | How to enable | Default model |
|---|---|---|
| `ollama` (default) | local endpoint `http://127.0.0.1:11434/v1` | `glm-5.3-flash:cloud` |
| `openai` (ChatGPT) | `export OPENAI_API_KEY=sk-...` | `gpt-4o-mini` |
| `zai` (Z.ai / Zhipu GLM) | `export ZAI_API_KEY=...` | `glm-4.6` |

Autodetect: if exactly one of the known keys is set, that provider is used
(`ZAI_API_KEY` wins over `OPENAI_API_KEY`; set `--provider` to be explicit).
Every value is overridable:

```bash
export OPENAI_API_KEY=sk-...
./.build/debug/harness --provider openai --model gpt-4o
export ZAI_API_KEY=...
./.build/debug/harness --provider zai --model glm-4.6
./.build/debug/harness --base-url https://api.z.ai/api/coding/paas/v4 --api-key KEY --model glm-4.6
```

Environment overrides: `HARNESS_BASE_URL`, `HARNESS_API_KEY`, `HARNESS_MODEL`,
`HARNESS_PROVIDER`. If pi is installed, its `~/.pi/agent/models.json` provider
is borrowed as a fallback — same trick pi itself uses for provider config.

Provider quirks live in one place (`LLMClient.swift`): e.g. newer OpenAI models
require `max_completion_tokens` instead of `max_tokens`.

## Design notes (what pi does, and why)

- **Tools report errors as text, not throws.** A failed `edit_file` comes back
  as "old_text appears 3 times…" so the model can read it and adapt. Only
  *infrastructure* failures (API down, turn cap) throw up to the REPL.
- **Turn cap + output truncation.** `maxTurns` (25) stops runaway loops;
  tool output is truncated (20k chars) before it enters context — a 50 MB build
  log is not context, it's a bill.
- **Watchdog on `bash`.** Commands run detached; after the deadline the child
  is `terminate()`d, then SIGKILL. Reading pipes to EOF *before*
  `waitUntilExit` avoids the classic pipe-buffer deadlock.
- **`edit_file` requires uniqueness.** Exact-match replacement that refuses
  ambiguous matches — this is what makes model edits safe to apply.

## Where to go next (exercises)

1. **Streaming (SSE)** — parse `data: {...}` chunks from
   `/chat/completions` with `URLSession.bytes(for:)`; print tokens as they
   arrive.
2. **Context compaction** — when history grows past N tokens, summarize old
   turns with the model and keep the tail (pi's `compaction.md`).
3. **Tool-approval gate** — confirm before `bash` runs; per-tool allowlists.
4. **JSONL sessions** — append one line per message instead of rewriting a
   JSON blob (pi's `session-format.md`); enables crash recovery.
5. **A second client** — implement `ChatModel` for Anthropic's native
   Messages API and compare the tool-use protocols.
6. **Sub-agents** — expose "spawn a fresh harness" as a tool.