import CoreGraphics
import Foundation
import Testing
@testable import Lasso

/// Regression: package tools and their cards, the Agent's history, images in context, save ordering.
/// Each test is a bug a QA pass found; it fails without its fix.
@MainActor
@Suite(.serialized)
struct ChatToolsAndAgentRegressionTests {
    private func convoFile(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lasso/conversations/\(id.uuidString).json")
    }

    private func withStore(_ manifest: String, _ body: (PackageStore, RecordingServer) async throws -> Void) async throws {
        let server = try await RecordingServer()
        let name = "lasso-qa3-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root); server.stop() }
        let package = try store.install(Data(manifest.utf8), origin: .file)
        if let setting = package.setting("server") { store.setValue(server.base, package.id, setting) }
        try await body(store, server)
    }

    // A. The chat model is offered over-budget tools (chatTools) but calling one fails: `call` only
    //    looks in offeredTools(), which excludes them.
    @Test func overBudgetToolOfferedToChatCanBeCalled() async throws {
        let commands = (1...9).map { i in
            #"{"id": "c\#(i)", "title": "C\#(i)", "surfaces": ["tool"], "input": ["args"], "output": "markdown", "run": {"prompt": "{{args.x}}"}, "tool": {"name": "t\#(i)", "description": "\#(i == 9 ? "Look up the zebra weather forecast. " : "")\#(String(repeating: "d", count: i == 9 ? 150 : 180))", "args": {"x": "string"}}}"#
        }.joined(separator: ", ")
        let many = #"{"lasso": 1, "id": "many-tools", "version": "1.0.0", "name": "Many", "summary": "S.", "author": "Me", "commands": [\#(commands)]}"#
        try await withStore(many) { _, _ in
            let t9 = try #require(PackageRegistry.shared.tools(localOnly: false).first { $0.name == "t9" })
            #expect(t9.overBudget, "precondition: t9 is over the budget")
            let offered = PackageToolCall.chatTools(for: "zebra weather forecast", recent: ["t9"]).map(\.name)
            #expect(offered.contains("t9"), "precondition: chat model is shown t9: \(offered)")
            let result = await PackageToolCall.call("t9", arguments: ["x": "hi"]) { _ in true }
            #expect(result.text != "No tool named t9.", "chat offered t9 but calling it says: \(result.text)")
        }
    }

    // B. Closing a chat while a package tool's approval card waits leaves the call (and the turn) hanging
    //    until the 280 s timeout: close() → cancelWork() never answers the card.
    @Test func closingChatDuringToolApprovalEndsTheCall() async throws {
        let manifest = """
        {"lasso": 1, "id": "tool-qa3", "version": "1.0.0", "name": "Tool qa3", "summary": "S.", "author": "Me",
         "settings": [{"id": "server", "label": "Server", "kind": "server"}],
         "commands": [
           {"id": "add", "title": "Add a task", "surfaces": ["send", "tool"], "input": ["text"], "output": "notify",
            "run": {"http": {"method": "POST", "url": "{{settings.server}}/add", "json": {"t": "{{text}}"}}, "answer": "msg"},
            "tool": {"name": "add_task", "description": "Add a task to the user's list.", "args": {"text": "string"}}}]}
        """
        try await withStore(manifest) { _, _ in
            let chat = ChatController.shared
            chat.newChat()
            let conversation = chat.active.id
            var reply = ChatMessage(role: .assistant, text: "")
            reply.isStreaming = true
            chat.messages.append(reply)
            chat.active.isStreaming = true
            let call = ToolCall(id: "1", name: "add_task", argumentsJSON: #"{"text": "Buy milk"}"#)
            let pending = Task { await chat.runPackageTool(call, assistantID: reply.id) }
            for _ in 0..<50 where chat.messages.first(where: { $0.id == reply.id })?.toolApproval == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(chat.messages.first { $0.id == reply.id }?.toolApproval != nil, "card should show")
            chat.close(conversation)
            var done = false
            Task { _ = await pending.value; done = true }
            for _ in 0..<60 where !done { try await Task.sleep(for: .milliseconds(50)) }
            let started = Date()
            #expect(done, "tool call still waiting on a card in a closed chat \(Int(Date().timeIntervalSince(started) + 3)) s after Close (it ends only at the 280 s timeout)")
        }
    }

    // C. The Agent's history (hermesHistory) still carries what round 2 removed from the regular model's:
    //    Lasso's /help note, "(No response.)", and the question of a failed reply.
    @Test func agentHistorySkipsLocalNotesNoResponseAndFailedQuestions() {
        var help = ChatMessage(role: .assistant, text: "HELP TEXT")
        help.isLocalNote = true
        var err = ChatMessage(role: .assistant, text: "Couldn't connect.")
        err.isError = true
        let msgs: [ChatMessage] = [
            ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
            help,
            ChatMessage(role: .user, text: "q-failed"), err,
            ChatMessage(role: .user, text: "q-empty"), ChatMessage(role: .assistant, text: "(No response.)"),
        ]
        let h = ChatController.hermesHistory(from: msgs[...])
        let texts = h.map(\.content)
        #expect(!texts.contains("HELP TEXT"), "local /help note sent to the Agent: \(texts)")
        #expect(!texts.contains("(No response.)"), "(No response.) sent to the Agent: \(texts)")
        #expect(!texts.contains("q-failed"), "question of a failed reply sent (two user turns in a row): \(h.map(\.role))")
    }

    // D. An Agent reply that answered only with an image (MEDIA:) has empty text, so `isAnswer` is false
    //    and historyTurns drops it AND the user's question.
    @Test func agentImageOnlyReplyKeepsItsQuestionInHistory() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        var reply = ChatMessage(role: .assistant, text: "")
        reply.viaAgent = true
        reply.attachments = [Attachment(image: image, sourcePath: "/tmp/chart.png")]
        let msgs: [ChatMessage] = [ChatMessage(role: .user, text: "draw me a chart of my disk usage"), reply]
        let texts = ChatController.historyTurns(from: msgs[...]).map(\.text)
        #expect(texts.contains { $0.contains("draw me a chart") }, "the answered question vanished from history: \(texts)")
    }

    // E. Images in history are re-sent with every later turn and never counted against the budget.
    @Test func historyImagesAreBudgeted() {
        let big = String(repeating: "A", count: 200_000)     // ~150 KB JPEG as base64
        var history: [ChatContextBuilder.HistoryTurn] = []
        for i in 0..<3 {
            history.append(.init(role: .user, text: "image \(i)", imageBase64s: Array(repeating: big, count: 5)))
            history.append(.init(role: .assistant, text: "ok \(i)"))
        }
        var builder = ChatContextBuilder()
        builder.budget.total = 4_000
        let out = builder.build(systemPrompt: "sys", memory: ConversationMemory(), history: history,
                                currentUserText: "and now a text question", currentImageBase64s: [])
        let images = out.turns.reduce(0) { $0 + $1.imageBase64s.count }
        #expect(images == 0 || images <= 5, "a text-only follow-up re-sends \(images) old images (\(images * big.count / 1000) KB), uncounted")
    }

    // F. A save queued just before Close lands after Close's delete: the closed chat is back on disk.
    @Test func closedChatStaysDeletedEvenWithASaveInFlight() async throws {
        let chat = ChatController.shared
        var resurrected = 0
        var ids: [UUID] = []
        for _ in 0..<20 {
            chat.newChat()
            let id = chat.active.id
            ids.append(id)
            chat.active.messages = [ChatMessage(role: .user, text: "secret \(id)"), ChatMessage(role: .assistant, text: "ok")]
            chat.postLocalMessage("HELP")   // persist → detached write
            chat.close(id)                    // synchronous delete, then index write
        }
        try await Task.sleep(for: .milliseconds(1500))
        for id in ids where FileManager.default.fileExists(atPath: convoFile(id).path) {
            resurrected += 1
            ConversationStore.delete(id: id)
        }
        #expect(resurrected == 0, "\(resurrected)/20 closed chats were written back to disk after Close")
    }
}
