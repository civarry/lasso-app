import Foundation
import Testing
@testable import Lasso

/// Regression: providers and models (streams, tool rounds, system turns, context windows, what's
/// local). Each test is a bug a QA pass found; it fails without its fix. Network tests use the
/// loopback RecordingServer only.
@Suite(.serialized)
struct IntelligenceRegressionTests {

    private func sse(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    // 1. Anthropic reports overload mid-stream as an SSE `error` event on an HTTP 200. Ignored, the
    //    reply ends empty with no error, so neither the user nor the fallback learns anything failed.
    @Test func anthropicMidStreamErrorEventIsThrown() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(status: 200, body: sse([
            #"{"type":"message_start","message":{"id":"m1"}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ])))
        let provider = AnthropicProvider(baseURL: URL(string: server.base)!, apiKey: "test-key", model: "claude-x")
        var text = ""
        var thrown: Error?
        do {
            for try await d in provider.respond(messages: [ChatTurn(role: .user, text: "hi")]) { text += d }
        } catch { thrown = error }
        #expect(thrown != nil, "stream finished silently with text=\(text.debugDescription)")
    }

    // 2. Anthropic's last tool round drops `tools` while the history still holds tool_use blocks
    //    (the API rejects that with a 400), and a model that still calls a tool ends with an empty
    //    reply instead of the "kept calling tools" error the OpenAI path gives.
    @Test func anthropicFinalToolRoundStillDefinesToolsAndReportsNoAnswer() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(status: 200, body: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"web_search"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"x\"}"}}"#,
            #"{"type":"message_stop"}"#,
        ])))
        let provider = AnthropicProvider(baseURL: URL(string: server.base)!, apiKey: "test-key", model: "claude-x")
        var thrown: Error?
        do {
            for try await _ in provider.respond(messages: [ChatTurn(role: .user, text: "news?")],
                                                tools: [.webSearch], execute: { _ in "result" }) {}
        } catch { thrown = error }
        let bodies = server.requests.compactMap {
            try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any]
        }
        #expect(bodies.count == maxToolRounds)
        let last = try #require(bodies.last)
        let lastHasToolUse = String(decoding: try JSONSerialization.data(withJSONObject: last), as: UTF8.self)
            .contains("tool_use")
        #expect(lastHasToolUse)
        #expect(last["tools"] != nil, "final round sends tool_use history without a tools definition")
        #expect(thrown != nil, "model never answered, but the stream finished with no error")
    }

    // 3. Gemini keeps only the first system turn: the conversation-memory and retrieval blocks the
    //    context builder injects as later system turns are silently dropped (Anthropic and MLX were
    //    fixed for exactly this).
    @Test func geminiWireKeepsEverySystemTurn() {
        let wire = GeminiAPI.wire([
            ChatTurn(role: .system, text: "You are Lasso."),
            ChatTurn(role: .system, text: "Durable facts: the user's name is Ana."),
            ChatTurn(role: .user, text: "What's my name?"),
        ], fallbackSystem: "fallback")
        #expect(wire.system.contains("Ana"), "system sent to Gemini: \(wire.system)")
    }

    // 4. Context detection: when the selected model isn't in the /models list, the first listed
    //    model's window is used instead (OpenRouter lists hundreds; the first may be 2M or 4K).
    @MainActor @Test func contextLengthIsNotBorrowedFromAnotherModel() throws {
        let body = Data(#"{"data":[{"id":"some/other-model","context_length":2000000},{"id":"x/y","context_length":8192}]}"#.utf8)
        let n = IntelligenceCoordinator.parseOpenAIContextLength(body, model: "meta-llama/llama-3.3-70b-instruct:free")
        #expect(n == nil, "borrowed \(String(describing: n)) tokens from an unrelated model")
    }

    // 5. Ollama "-cloud" models (served by ollama.com through the local daemon) are treated as
    //    local: the provider reports isLocal, local-only lets it through, and Auto even prefers one.
    @Test func ollamaCloudModelIsNotLocal() {
        #expect(OllamaProvider(model: "gpt-oss:120b-cloud").isLocal == false)
        let pick = OllamaModels.bestTextModel(["llama3.2:3b", "qwen3-coder:480b-cloud"])
        #expect(pick == "llama3.2:3b", "Auto picked \(pick ?? "nil")")
    }

    // 6. MLX chat context window comes from an embedding helper that defaults to 512 tokens (and
    //    caps at 8192) when the config isn't in the HF cache (Auto selection, or a model in ~/models
    //    or LM Studio), so the chat budget collapses to the 2048-token floor.
    @Test func mlxChatWindowDoesNotDefaultTo512() {
        let tokens = MLXProvider.chatContextTokens("qa-nonexistent/Some-Chat-7B-4bit")
        let budget = ChatContextBuilder.Budget.forContextTokens(
            tokens, isLocal: true, localSweetSpot: ChatContextBuilder.Budget.localSweetSpot(paramsBillions: 7))
        #expect(tokens > 512)
        // Not collapsed to the 2,048-token floor (8,192 chars) it fell to with the 512 default.
        #expect(budget.total > 2_048 * 4, "chat budget is \(budget.total) chars (~\(budget.total / 4) tokens)")
    }
}
