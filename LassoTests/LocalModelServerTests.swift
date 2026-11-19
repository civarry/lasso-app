import Testing
import Foundation
@testable import Lasso

/// The OpenAI ⇄ chat-template translation behind `LocalModelServer` (pure), plus an opt-in live run of
/// the real server on a real MLX model:
///
///     TEST_RUNNER_LASSO_MLX_SERVER=<mlx model id> xcodebuild test -scheme Lasso -only-testing:LassoTests/LocalModelServerTests
struct LocalModelServerTests {
    @Test func toolTurnsBecomeTemplateMessages() throws {
        let raw: [[String: Any]] = [
            ["role": "developer", "content": "Be brief."],
            ["role": "user", "content": [["type": "text", "text": "list files"], ["type": "image_url", "image_url": [:]]]],
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "call_1", "type": "function",
                 "function": ["name": "terminal", "arguments": "{\"command\":\"ls\",\"timeout\":5}"]],
            ]],
            ["role": "tool", "tool_call_id": "call_1", "content": "a.txt"],
        ]
        let messages = OpenAIBridge.templateMessages(raw)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "list files")
        #expect(messages[2]["content"] as? String == "")
        let call = try #require((messages[2]["tool_calls"] as? [[String: any Sendable]])?.first)
        let function = try #require(call["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "terminal")
        // Qwen's template iterates the arguments, so they must be a dictionary, not the JSON string.
        let arguments = try #require(function["arguments"] as? [String: any Sendable])
        #expect(arguments["command"] as? String == "ls")
        #expect(arguments["timeout"] as? Int == 5)
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
    }

    @Test func laterSystemMessagesJoinTheFirst() {
        let messages = OpenAIBridge.templateMessages([
            ["role": "system", "content": "A"], ["role": "user", "content": "hi"],
            ["role": "system", "content": "B"], ["role": "assistant", "content": "yo"],
        ])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant"])
        #expect(messages[0]["content"] as? String == "A\n\nB")
    }

    @Test func jsonTypesSurviveAsTemplateValues() {
        let object = try! JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1.5,"c":2,"d":null,"e":["x"]}"#.utf8))
        let value = OpenAIBridge.sendable(object) as? [String: any Sendable]
        #expect(value?["a"] as? Bool == true)
        #expect(value?["b"] as? Double == 1.5)
        #expect(value?["c"] as? Int == 2)
        #expect(value?["d"] == nil)
        #expect((value?["e"] as? [any Sendable])?.first as? String == "x")
    }

    @Test func requestIsParsedOnlyWhenTheBodyHasArrived() {
        let full = Data("POST /v1/chat/completions HTTP/1.1\r\nAuthorization: Bearer t\r\nContent-Length: 4\r\n\r\n{\"a\"".utf8)
        #expect(HTTPRequest.parse(full.prefix(full.count - 2)) == nil)
        let request = HTTPRequest.parse(full)
        #expect(request?.path == "/v1/chat/completions")
        #expect(request?.headers["authorization"] == "Bearer t")
        #expect(request?.body.count == 4)
    }

    @Test func toolCallsAreReportedTheOpenAIWay() throws {
        let done = OpenAIBridge.completion(id: "x", model: "m", content: "", calls: [("terminal", #"{"command":"ls"}"#)],
                                           ids: ["call_a"], reason: "tool_calls", usage: nil)
        let choice = try #require((done["choices"] as? [[String: Any]])?.first)
        #expect(choice["finish_reason"] as? String == "tool_calls")
        let call = try #require(((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?.first)
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"command":"ls"}"#)
    }

    // MARK: Live

    private static let liveModel = ProcessInfo.processInfo.environment["LASSO_MLX_SERVER"]

    private func post(_ base: URL, token: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    @Test(.enabled(if: liveModel != nil), .timeLimit(.minutes(10)))
    func liveServerAnswersAndCallsTools() async throws {
        let model = try #require(Self.liveModel)
        let server = LocalModelServer.shared
        let base = try await server.start(model: model)
        defer { server.stop() }

        // Wrong key: refused.
        let (_, refused) = try await post(base, token: "nope", ["messages": [["role": "user", "content": "hi"]]])
        #expect(refused == 401)

        // The models list carries a context window Hermes accepts (>= 64K).
        var list = URLRequest(url: base.appending(path: "models"))
        list.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let (listData, _) = try await URLSession.shared.data(for: list)
        let models = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let entry = (models?["data"] as? [[String: Any]])?.first
        print("[model-server] models: \(entry ?? [:])")
        #expect((entry?["context_length"] as? Int ?? 0) >= 64_000)

        // A tool the model should call.
        let tools: [[String: Any]] = [["type": "function", "function": [
            "name": "get_weather", "description": "Current weather for a city.",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
        ]]]
        let started = Date()
        let (data, status) = try await post(base, token: server.token, [
            "model": model, "tools": tools,
            "messages": [["role": "system", "content": "Use tools when they help."],
                         ["role": "user", "content": "What's the weather in Manila right now?"]],
        ])
        print("[model-server] tool turn \(status) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(String(decoding: data, as: UTF8.self).prefix(400))")
        #expect(status == 200)
        let choice = (try JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["choices"] as? [[String: Any]])?.first }
        #expect(choice?["finish_reason"] as? String == "tool_calls")
        let call = ((choice?["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?.first
        let function = call?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "get_weather")
        #expect((function?["arguments"] as? String)?.contains("Manila") == true)

        // The tool's result goes back in; the model answers with it.
        let (answer, answerStatus) = try await post(base, token: server.token, [
            "model": model, "tools": tools, "stream": false,
            "messages": [["role": "user", "content": "What's the weather in Manila right now?"],
                         ["role": "assistant", "content": "", "tool_calls": [call ?? [:]]],
                         ["role": "tool", "tool_call_id": call?["id"] ?? "", "content": "31°C, light rain"]],
        ])
        let text = String(decoding: answer, as: UTF8.self)
        print("[model-server] after tool: \(text.prefix(300))")
        #expect(answerStatus == 200)
        #expect(text.contains("31"))
    }
}
