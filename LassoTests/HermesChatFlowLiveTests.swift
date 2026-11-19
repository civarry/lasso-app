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
        #expect(plain.steps.contains { $0.text.hasPrefix("Answering · ") })
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
}
