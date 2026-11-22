import Foundation
import Testing
@testable import Lasso

/// Regression: what the model's history holds, and what's saved, cleared and restored. Each test is a
/// bug a QA pass found; it fails without its fix.
@MainActor
@Suite(.serialized)
struct ChatHistoryAndSavingRegressionTests {
    private func file(_ path: String = "/tmp/qa-r2-\(UUID().uuidString).txt") -> FileAttachment {
        FileAttachment(id: UUID(), path: path, name: "notes.txt", kind: .text, typeName: "Plain text", bytes: 10)
    }
    private func convoFile(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lasso/conversations/\(id.uuidString).json")
    }

    // 1. Errors / "(Stopped.)" / local /help reach the regular model as assistant turns.
    @Test func historySentToModelSkipsErrorsStoppedAndLocalNotes() {
        var err = ChatMessage(role: .assistant, text: "Couldn't connect to Ollama at localhost:11434.")
        err.isError = true
        let msgs: [ChatMessage] = [
            ChatMessage(role: .user, text: "q1"), err,
            ChatMessage(role: .user, text: "q2"), ChatMessage(role: .assistant, text: "(Stopped.)"),
        ]
        let texts = ChatController.historyTurns(from: msgs[...]).map(\.text)
        #expect(!texts.contains { $0.contains("Couldn't connect") }, "error sent as history: \(texts)")
        #expect(!texts.contains("(Stopped.)"), "stopped placeholder sent as history: \(texts)")
    }

    @Test func localHelpNoteIsNotSentToModel() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "real answer")]
        chat.postLocalMessage("HELP TEXT")
        let texts = ChatController.historyTurns(from: chat.active.messages[...]).map(\.text)
        #expect(!texts.contains("HELP TEXT"), "local /help sent as an assistant turn: \(texts)")
    }

    // 2. isError isn't persisted: an error reply comes back as a real answer after relaunch.
    @Test func errorFlagSurvivesSaveAndLoad() {
        let c = Conversation()
        var err = ChatMessage(role: .assistant, text: "Couldn't reach the model.")
        err.isError = true
        c.messages = [ChatMessage(role: .user, text: "hi"), err]
        let back = ConversationStore.rebuild(ConversationStore.snapshot(c))
        #expect(back.messages[1].isError, "error reply restored as a normal answer")
    }

    // 3. /clear keeps the old auto-title, staged files and mentions.
    @Test func clearResetsTitleAndStagedFiles() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "plan my trip"), ChatMessage(role: .assistant, text: "ok")]
        chat.active.autoTitle = "Trip Planning"
        chat.active.pendingFiles = [file()]
        chat.clearActive()
        chat.active.messages = [ChatMessage(role: .user, text: "fix my parser")]
        #expect(chat.active.title != "Trip Planning", "cleared chat still titled: \(chat.active.title)")
        #expect(chat.active.pendingFiles.isEmpty, "staged file survived /clear")
    }

    @Test func stagedFileAloneCountsAsSomethingToClear() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.pendingFiles = [file()]
        #expect(chat.canClear, "a staged file alone: canClear false, so New chat is a no-op")
    }

    // 4. Deleting every message leaves the old file on disk, so it all comes back on relaunch.
    @Test func deletingEverythingRemovesTheSavedFile() async throws {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "my secret"), ChatMessage(role: .assistant, text: "noted")]
        chat.postLocalMessage("HELP")     // persists
        try await Task.sleep(for: .milliseconds(500))
        #expect(FileManager.default.fileExists(atPath: convoFile(id).path), "precondition: file written")
        chat.deleteFromHere(chat.active.messages[0].id)
        #expect(chat.active.messages.isEmpty)
        try await Task.sleep(for: .milliseconds(500))
        let restored = ConversationStore.loadAll().first { $0.id == id }
        #expect(restored == nil, "deleted chat reloads from disk with: \(restored?.messages.map(\.text) ?? [])")
    }

    // 5. "Continue in chat" isn't saved until a turn completes.
    @Test func continueInChatIsSaved() async throws {
        let chat = ChatController.shared
        chat.continueWith(question: "what is this", answer: "a cat", context: nil, image: nil)
        let id = chat.active.id
        defer { chat.close(id) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: convoFile(id).path), "seeded conversation not persisted")
    }

    // 6. lastReplyText (what a bare /command runs on) picks "(Stopped.)" or local /help text.
    @Test func lastReplyTextSkipsStoppedAndLocalNotes() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.active.messages = [ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "real answer"),
                                ChatMessage(role: .user, text: "q2"), ChatMessage(role: .assistant, text: "(Stopped.)")]
        #expect(chat.lastReplyText != "(Stopped.)", "bare /command would run on \"(Stopped.)\"")
        chat.active.messages.removeLast(2)
        chat.postLocalMessage("HELP TEXT")
        #expect(chat.lastReplyText == "real answer", "bare /command would run on: \(chat.lastReplyText ?? "nil")")
    }

    // 7. Regenerating a package /command reply wipes the composer draft (the deferred start clears input).
    @Test func regeneratingASlashReplyKeepsTheDraft() async throws {
        let server = try await RecordingServer()
        defer { server.stop() }
        server.answer(.init(body: Data(#"{"out": "hola mundo"}"#.utf8)))
        server.answer(.init(body: Data(#"{"out": "hola mundo 2"}"#.utf8)))
        let name = "lasso-qa-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        let real = PackageStore.shared
        let store = PackageStore(root: root, defaults: UserDefaults(suiteName: name)!)
        PackageStore.shared = store
        defer { PackageStore.shared = real; real.reload(); try? FileManager.default.removeItem(at: root) }
        let package = try store.install(Data(PackageSurfaceTests.manifest.utf8), origin: .file)
        store.setValue(server.base, package.id, try #require(package.setting("server")))

        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        chat.send(text: "/tr hello world")
        for _ in 0..<50 where chat.isStreaming || chat.messages.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        let reply = try #require(chat.messages.last)
        chat.input = "half-written follow-up"
        chat.regenerate(reply.id)
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<50 where chat.isStreaming { try await Task.sleep(for: .milliseconds(100)) }
        #expect(chat.input == "half-written follow-up", "draft after regenerate: \"\(chat.input)\"")
    }
}
