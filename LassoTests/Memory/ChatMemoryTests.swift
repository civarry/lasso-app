import Foundation
import Testing
@testable import Lasso

/// Memory: what the chat keeps alive after you're done with it. A closed conversation, its messages
/// and images must be freed, and per-reply state must not pile up for chats that are gone.
@MainActor
@Suite(.serialized)
struct ChatMemoryTests {
    /// Waits a moment for tasks that hold the object to finish, then checks it's gone.
    func released(_ check: () -> Bool) async throws -> Bool {
        for _ in 0..<30 { if check() { return true }; try await Task.sleep(for: .milliseconds(50)) }
        return check()
    }

    @Test func aClosedConversationIsFreed() async throws {
        let chat = ChatController.shared
        chat.newChat()
        weak var gone: Conversation? = chat.active
        let id = chat.active.id
        chat.active.messages = [ChatMessage(role: .user, text: "hi"), ChatMessage(role: .assistant, text: "hello")]
        chat.postLocalMessage("note")
        chat.close(id)
        ConversationStore.flush()
        #expect(try await released { gone == nil }, "the closed conversation is still alive")
    }

    @Test func aStoppedReplyDoesNotKeepItsConversationAlive() async throws {
        let chat = ChatController.shared
        chat.newChat()
        weak var gone: Conversation? = chat.active
        let id = chat.active.id
        chat.send(text: "tell me a long story")
        chat.cancelStreaming()
        chat.close(id)
        ConversationStore.flush()
        #expect(try await released { gone == nil }, "a stopped turn's task still holds the closed conversation")
    }

    @Test func codeRunsOfAClosedChatAreDropped() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        let reply = ChatMessage(role: .assistant, text: "```python\nprint(1)\n```")
        chat.active.messages = [ChatMessage(role: .user, text: "run"), reply]
        let key = CodeRunner.key(reply.id, "print(1)")
        CodeRunner.shared.runs[key] = CodeRunner.Run(title: "Run", lines: [], console: nil, error: nil, running: false,
                                                     started: Date(), elapsed: 0.1, packageID: "p", commandID: "c",
                                                     code: "print(1)", language: "python", reply: reply.text)
        chat.close(id)
        #expect(CodeRunner.shared.runs[key] == nil, "a closed chat's code runs stay in memory for the rest of the session")
    }
}
