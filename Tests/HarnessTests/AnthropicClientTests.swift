import Foundation
import Testing
@testable import HarnessCore

// ---------------------------------------------------------------------------
// AnthropicClientTests — network-free verification of the second dialect.
//
// The interesting assertions are the *mappings*: request-body translation
// (system hoisting, tool_use blocks, tool_result-as-user) and SSE reassembly
// (typed events, partial_json fragments). No HTTP is performed.
// ---------------------------------------------------------------------------

@Suite("Anthropic client")
struct AnthropicClientTests {
    private var config = Config(
        provider: "anthropic",
        baseURL: "https://api.anthropic.com/v1",
        apiKey: "sk-ant-test",
        model: "claude-sonnet-4-5"
    )

    @Test("system messages hoist into the top-level system parameter")
    func systemHoisted() {
        let messages = [
            Message.system("be terse"),
            Message.user("hi"),
        ]
        let body = AnthropicClient.requestBody(messages, tools: [], config: config)
        #expect(body["system"]?.stringValue == "be terse")
        let chat = body["messages"]?.arrayValue ?? []
        #expect(chat.count == 1)  // system never becomes a message
        #expect(chat[0].objectValue?["role"]?.stringValue == "user")
    }

    @Test("assistant tool calls become tool_use content blocks with parsed input")
    func toolUseBlocks() throws {
        let call = ToolCall(id: "t1", function: .init(name: "bash", arguments: #"{"cmd":"ls"}"#))
        let messages = [Message.user("run it"),
                        Message(role: "assistant", content: "on it", toolCalls: [call])]
        let body = AnthropicClient.requestBody(messages, tools: [], config: config)
        let turns = body["messages"]?.arrayValue ?? []
        let blocks = turns[1].objectValue?["content"]?.arrayValue ?? []
        #expect(blocks.count == 2)
        #expect(blocks[0].objectValue?["type"]?.stringValue == "text")
        let toolUse = blocks[1].objectValue
        #expect(toolUse?["type"]?.stringValue == "tool_use")
        #expect(toolUse?["id"]?.stringValue == "t1")
        #expect(toolUse?["name"]?.stringValue == "bash")
        #expect(toolUse?["input"]?.objectValue?["cmd"]?.stringValue == "ls")  // parsed, not a string
    }

    @Test("tool results become user messages with tool_result blocks")
    func toolResultBlocks() {
        let call = ToolCall(id: "t1", function: .init(name: "bash", arguments: "{}"))
        let messages = [Message.tool(result: "file.txt", for: call)]
        let body = AnthropicClient.requestBody(messages, tools: [], config: config)
        let turn = body["messages"]?.arrayValue?.first?.objectValue
        #expect(turn?["role"]?.stringValue == "user")  // not role "tool"
        let block = turn?["content"]?.arrayValue?.first?.objectValue
        #expect(block?["type"]?.stringValue == "tool_result")
        #expect(block?["tool_use_id"]?.stringValue == "t1")
        #expect(block?["content"]?.stringValue == "file.txt")
    }

    @Test("unparseable tool arguments map to input {} instead of crashing")
    func malformedArguments() {
        let call = ToolCall(id: "t2", function: .init(name: "bash", arguments: "not-json"))
        let messages = [Message(role: "assistant", content: nil, toolCalls: [call])]
        let body = AnthropicClient.requestBody(messages, tools: [], config: config)
        let block = body["messages"]?.arrayValue?.first?.objectValue?["content"]?
            .arrayValue?.first?.objectValue
        #expect(block?["input"]?.objectValue == [:])
    }

    @Test("tools map to input_schema; auth + endpoint ride on the request")
    func toolsAndRequest() {
        let tool = ToolSpec(name: "bash", description: "run shell",
                            parameters: .object(["type": .string("object")]),
                            run: { _, _ in "" })
        let body = AnthropicClient.requestBody([Message.user("go")], tools: [tool], config: config)
        let toolEntry = body["tools"]?.arrayValue?.first?.objectValue
        #expect(toolEntry?["name"]?.stringValue == "bash")
        #expect(toolEntry?["input_schema"]?.objectValue?["type"]?.stringValue == "object")
        #expect(toolEntry?["function"] == nil)  // no OpenAI nesting
        #expect(body["max_tokens"]?.intValue == config.maxTokens)

        let request = AnthropicClient.request(for: [Message.user("go")], tools: [], config: config, streaming: false)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("stop_reason maps onto the loop's finish vocabulary")
    func stopReasons() {
        #expect(AnthropicClient.finishReason(for: "tool_use") == "tool_calls")
        #expect(AnthropicClient.finishReason(for: "end_turn") == "stop")
        #expect(AnthropicClient.finishReason(for: "max_tokens") == "length")
        #expect(AnthropicClient.finishReason(for: nil) == "unknown")
    }

    @Test("non-streaming response: content blocks decode into an AssistantTurn")
    func responseDecoding() throws {
        let payload = """
        {"content":[{"type":"text","text":"checking…"},
                    {"type":"tool_use","id":"t9","name":"grep","input":{"pattern":"x"}}],
         "stop_reason":"tool_use",
         "usage":{"input_tokens":12,"output_tokens":7}}
        """
        let turn = try AnthropicClient.turn(from: JSONValue.parse(payload)!)
        #expect(turn.text == "checking…")
        #expect(turn.finishReason == "tool_calls")
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls[0].id == "t9")
        #expect(turn.toolCalls[0].function.arguments == #"{"pattern":"x"}"#)
        #expect(turn.usage?.promptTokens == 12 && turn.usage?.completionTokens == 7)
    }

    @Test("SSE: typed events reassemble text, tool calls, usage, stop reason")
    func sseAssembly() {
        var assembler = AnthropicSSEAssembler()
        let events = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"bash"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var fragments = ""
        for event in events {
            guard let parsed = JSONValue.parse(event) else {
                Issue.record("event failed to parse: \(event)")
                continue
            }
            fragments += assembler.ingest(parsed)
        }
        #expect(fragments == "Hello")
        let turn = assembler.assembled()
        #expect(turn.text == "Hello")
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls[0].id == "c1" && turn.toolCalls[0].function.name == "bash")
        #expect(turn.toolCalls[0].function.arguments == #"{"cmd":"ls"}"#)
        #expect(turn.finishReason == "tool_calls")
        #expect(turn.usage?.promptTokens == 10 && turn.usage?.completionTokens == 5)
    }

    @Test("provider resolution: ANTHROPIC_API_KEY autodetects; explicit flag needs no key")
    func providerResolution() {
        let byEnv = Config.resolve(arguments: [], env: ["ANTHROPIC_API_KEY": "sk-ant"], pi: PIConfigSnapshot())
        #expect(byEnv.provider == "anthropic")
        #expect(byEnv.baseURL == "https://api.anthropic.com/v1")
        #expect(byEnv.model == "claude-sonnet-4-5")

        let explicit = Config.resolve(arguments: ["--provider", "anthropic"], env: [:], pi: PIConfigSnapshot())
        #expect(explicit.provider == "anthropic" && explicit.apiKey == "none")

        let factory = makeChatModel(for: Config(provider: "anthropic", baseURL: "https://api.anthropic.com/v1",
                                                apiKey: "k", model: "claude-sonnet-4-5"))
        #expect(factory is AnthropicClient)
        #expect(makeChatModel(for: Config(provider: "openai", baseURL: "https://api.openai.com/v1",
                                          apiKey: "k", model: "gpt-4o-mini")) is OpenAICompatClient)
    }
}