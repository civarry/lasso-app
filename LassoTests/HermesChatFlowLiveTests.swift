import Testing
import Foundation
@testable import Lasso

/// The chat's Agent end to end, through `ChatController` itself: the same calls the panel's buttons make
/// (Agent button, Send, Allow/Deny, Stop, Regenerate), against Lasso's own Hermes. Runs in a fresh
/// conversation that it closes (and so deletes) at the end, and puts the Agent setting back. Opt-in:
///
///     TEST_RUNNER_LASSO_HERMES_CHAT=1 xcodebuild test -scheme Lasso -only-testing:LassoTests/HermesChatFlowLiveTests
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["LASSO_HERMES_CHAT"] == "1"))
struct HermesChatFlowLiveTests {
    private let chat = ChatController.shared

    private func lastReply() -> ChatMessage? { chat.messages.last { $0.role == .assistant } }

    /// These test Lasso's own Hermes: "Use my own Hermes" is turned off for the test and put back after.
    private func usingLassosHermes() -> () -> Void {
        let key = HermesAgent.useOwnHermesKey
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        return { UserDefaults.standard.set(was, forKey: key) }
    }

    private func waitUntil(_ seconds: Double = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
    }

    private func send(_ text: String) async throws {
        chat.send(text: text)
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntil { !chat.isStreaming || lastReply()?.approval != nil }
    }

    private func dump(_ label: String) {
        let m = lastReply()
        print("[hermes-chat] \(label): steps=\(m?.steps.map(\.text) ?? []) text=\(m?.text.prefix(100) ?? "") error=\(m?.isError ?? false) notice=\(m?.notice ?? "-")")
    }

    @Test func agentTurnsThroughTheController() async throws {
        let restoreOwnHermes = usingLassosHermes()
        defer { restoreOwnHermes() }
        let agentWasOn = chat.hermesSelected
        chat.newChat()
        let conversation = chat.active.id
        defer {
            chat.close(conversation)
            if chat.hermesSelected != agentWasOn { chat.hermesSelected = agentWasOn }
            HermesRuntime.shared.stop()
        }
        if !chat.hermesSelected { chat.toggleAgent() }   // the Agent button
        #expect(chat.agentAvailable && chat.hermesActive)

        // 1. A plain turn: the answer, and a trace naming the model.
        try await send("Reply with exactly: lasso-ok. Use no tools.")
        dump("plain")
        let plain = try #require(lastReply())
        #expect(!plain.isError)
        #expect(plain.text.contains("lasso-ok"))
        #expect(plain.steps.isEmpty, "a plain answer has no trace")
        #expect(plain.steps.allSatisfy { $0.done })
        #expect(plain.notice == nil)

        // 2. A flagged command: the card appears, Deny is honoured, the folder survives.
        let dir = URL(fileURLWithPath: "/private/tmp/lasso-chat-live-\(UUID().uuidString.prefix(6))")
        let junk = dir.appending(path: "junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        chat.send(text: "Run exactly this terminal command and nothing else: rm -r \(junk.path) . If it is denied, don't try anything else; say so in one sentence.")
        try await waitUntil { lastReply()?.approval != nil || !chat.isStreaming }
        dump("approval shown")
        let card = try #require(lastReply()?.approval, "no approval card")
        #expect(card.command?.contains("rm -r") == true)
        #expect(card.offered == ["once", "session", "deny"])
        chat.respondToApproval(try #require(lastReply()).id, choice: "deny")
        #expect(lastReply()?.approval == nil, "card should go at once")
        try await waitUntil { !chat.isStreaming }
        dump("denied")
        #expect(lastReply()?.steps.contains { $0.text == "You denied the command" } == true)
        #expect(FileManager.default.fileExists(atPath: junk.path), "denied rm -r deleted the folder")

        // 3. Stop while a command runs: the reply says Stopped and the command never finishes.
        let marker = dir.appending(path: "marker")
        chat.send(text: "Run this single terminal command in the foreground and wait for it: sleep 20 && touch \(marker.path) . Then say done.")
        try await waitUntil(60) { lastReply()?.steps.contains { $0.text.hasPrefix("Ran a command") } == true }
        try await Task.sleep(for: .seconds(1))
        chat.cancelStreaming()   // the Stop button
        dump("stopped")
        #expect(!chat.isStreaming)
        #expect(lastReply()?.approval == nil)
        try await Task.sleep(for: .seconds(23))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command kept running after Stop")

        // 4. Regenerate the first answer: history is Lasso's, so the rewritten thread works.
        let firstReply = try #require(chat.messages.first { $0.role == .assistant })
        chat.regenerate(firstReply.id)
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntil { !chat.isStreaming }
        dump("regenerated")
        #expect(chat.messages.count == 2)
        #expect(lastReply()?.text.contains("lasso-ok") == true)

        // 5. Agent off: the gateway goes away.
        chat.toggleAgent()
        #expect(!chat.hermesActive)
        try await waitUntil(5) { HermesRuntime.shared.state == .stopped }
        #expect(HermesRuntime.shared.state == .stopped)
    }

    /// With an MLX model chosen in Lasso, the Agent must think with it (served by `LocalModelServer`),
    /// not fall back to Hermes's own model. Needs TEST_RUNNER_LASSO_TEST_MLX=<model id>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LASSO_TEST_MLX"] != nil), .timeLimit(.minutes(15)))
    func agentRunsOnLassosMLXModel() async throws {
        let restoreOwnHermes = usingLassosHermes()
        defer { restoreOwnHermes() }
        let model = try #require(ProcessInfo.processInfo.environment["LASSO_TEST_MLX"])
        let intelligence = IntelligenceCoordinator.shared
        let (providerWas, mlxWas, agentWas) = (intelligence.preferred, intelligence.mlxModel, chat.hermesSelected)
        intelligence.preferred = .mlx
        intelligence.mlxModel = model
        chat.newChat()
        let conversation = chat.active.id
        defer {
            chat.close(conversation)
            if chat.hermesSelected != agentWas { chat.hermesSelected = agentWas }
            intelligence.preferred = providerWas
            intelligence.mlxModel = mlxWas
            HermesRuntime.shared.stop()
        }
        if !chat.hermesSelected { chat.toggleAgent() }

        let route = await HermesRoute.current(intelligence)
        #expect(route?.provider == "custom")
        #expect(route?.baseURL?.hasPrefix("http://127.0.0.1:") == true)
        let config = { (try? String(contentsOf: HermesRuntime.profileDirectory.appending(path: "config.yaml"), encoding: .utf8)) ?? "" }

        for (n, ask) in ["Reply with exactly: lasso-ok. Use no tools.",
                         "Run the terminal command `touch lasso-workspace-check && echo lasso-tool-ok` and tell me what it printed."].enumerated() {
            let started = Date()
            chat.send(text: ask)
            try await Task.sleep(for: .milliseconds(100))
            try await waitUntil(400) { !chat.isStreaming || lastReply()?.approval != nil }
            let seconds = Date().timeIntervalSince(started)
            dump("mlx turn \(n + 1) in \(String(format: "%.1f", seconds))s")
            let reply = try #require(lastReply())
            #expect(!reply.isError, "\(reply.text.prefix(200))")
            #expect(!reply.steps.contains { $0.text.hasPrefix("Using Hermes's own model") }, "fell back to Hermes's model")
            #expect(route?.label.contains("MLX") == true, "the header should name the MLX model")
            #expect(reply.text.contains(n == 0 ? "lasso-ok" : "lasso-tool-ok"))
            if n == 1 { #expect(reply.steps.contains { $0.text.hasPrefix("Ran a command") }, "no tool actually ran") }
        }
        // The command ran in the agent's workspace, not the hidden profile or the home folder.
        let check = HermesRuntime.workspaceDirectory.appending(path: "lasso-workspace-check")
        #expect(FileManager.default.fileExists(atPath: check.path), "the agent's command didn't run in ~/LassoWorkspace")
        try? FileManager.default.removeItem(at: check)
        // A fresh profile, and Hermes's main model is Lasso's (its side tasks follow it), not a cloud default.
        #expect(HermesRuntime.profileIsFresh)
        let block = config().components(separatedBy: HermesProfileFiles.beginMarker).last ?? ""
        #expect(block.contains("default: \"\(model)\""))
        #expect(block.contains("base_url: \"http://127.0.0.1:"))
    }

    /// Ollama through the Agent: Ollama's OpenAI endpoint ignores `num_ctx`, so without the Agent variant
    /// every turn hit the 4,096-token default. Needs TEST_RUNNER_LASSO_TEST_OLLAMA=<model> and Ollama running.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LASSO_TEST_OLLAMA"] != nil), .timeLimit(.minutes(15)))
    func agentRunsOnOllamaWithEnoughContext() async throws {
        let restoreOwnHermes = usingLassosHermes()
        defer { restoreOwnHermes() }
        let model = try #require(ProcessInfo.processInfo.environment["LASSO_TEST_OLLAMA"])
        let intelligence = IntelligenceCoordinator.shared
        let (providerWas, modelWas, agentWas) = (intelligence.preferred, intelligence.ollamaModel, chat.hermesSelected)
        intelligence.preferred = .ollama
        intelligence.ollamaModel = model
        chat.newChat()
        let conversation = chat.active.id
        defer {
            chat.close(conversation)
            if chat.hermesSelected != agentWas { chat.hermesSelected = agentWas }
            intelligence.preferred = providerWas
            intelligence.ollamaModel = modelWas
            HermesRuntime.shared.stop()
        }
        let route = await HermesRoute.current(intelligence)
        #expect(route?.model == OllamaAgentModel.name(for: model))
        #expect(await OllamaAgentModel.numCtx(of: OllamaAgentModel.name(for: model), baseURL: OllamaEndpoint.baseURL) ?? 0 >= 64_000)
        if !chat.hermesSelected { chat.toggleAgent() }
        for (n, ask) in ["Reply with exactly: lasso-ok. Use no tools.",
                         "Run the terminal command `touch lasso-workspace-check && echo lasso-tool-ok` and tell me what it printed."].enumerated() {
            let started = Date()
            chat.send(text: ask)
            try await Task.sleep(for: .milliseconds(100))
            try await waitUntil(600) { !chat.isStreaming || lastReply()?.approval != nil }
            dump("ollama turn \(n + 1) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            let reply = try #require(lastReply())
            #expect(!reply.isError, "\(reply.text.prefix(200))")
            #expect(reply.text.contains(n == 0 ? "lasso-ok" : "lasso-tool-ok"))
            // The words alone prove nothing: a model without tool support writes a made-up call and its
            // "output" as text (seen with an imported Gemma 4 GGUF). The command must actually have run.
            if n == 1 { #expect(reply.steps.contains { $0.text.hasPrefix("Ran a command") }, "no tool actually ran") }
        }
        // The command ran in the agent's workspace, not the hidden profile or the home folder.
        let check = HermesRuntime.workspaceDirectory.appending(path: "lasso-workspace-check")
        #expect(FileManager.default.fileExists(atPath: check.path), "the agent's command didn't run in ~/LassoWorkspace")
        try? FileManager.default.removeItem(at: check)
    }

    /// After Agent is turned off, the regular model must not take the Agent's "I opened Chrome" in the
    /// history as something it can do (seen: it claimed to open apps it couldn't).
    @Test func regularChatDoesNotClaimAgentActions() async throws {
        let agentWasOn = chat.hermesSelected
        if agentWasOn { chat.toggleAgent() }
        // A small local model, the most prone to this, cached on this Mac (TEST_RUNNER_LASSO_TEST_MLX).
        let intelligence = IntelligenceCoordinator.shared
        let (providerWas, mlxWas) = (intelligence.preferred, intelligence.mlxModel)
        if let model = ProcessInfo.processInfo.environment["LASSO_TEST_MLX"] {
            intelligence.preferred = .mlx
            intelligence.mlxModel = model
        }
        chat.newChat()
        let conversation = chat.active.id
        defer {
            chat.close(conversation)
            if chat.hermesSelected != agentWasOn { chat.hermesSelected = agentWasOn }
            intelligence.preferred = providerWas
            intelligence.mlxModel = mlxWas
        }
        var reply = ChatMessage(role: .assistant, text: "Opened Chrome for you.")
        reply.viaAgent = true
        chat.messages = [ChatMessage(role: .user, text: "open chrome"), reply]

        let claims = ["opened", "launched", "launching", "i've started", "is now open", "now open"]
        var failures: [String] = []
        for ask in ["now open Safari", "open the Notes app please", "can you open Finder", "what did you do earlier?"] {
            chat.send(text: ask)
            try await Task.sleep(for: .milliseconds(100))
            try await waitUntil { !chat.isStreaming }
            let text = (lastReply()?.text ?? "").lowercased()
            // A failed model call would pass this vacuously.
            #expect(lastReply()?.isError == false, "the model didn't answer: \(text.prefix(120))")
            print("[hermes-chat] agent off, '\(ask)' -> \(text.prefix(160))")
            if claims.contains(where: { text.contains($0) }) { failures.append(ask) }
        }
        print("[hermes-chat] rule in prompt: \(ChatController.systemPrompt.contains("Agent mode"))")
        #expect(failures.isEmpty, "claimed an action it can't take: \(failures)")
    }
}
