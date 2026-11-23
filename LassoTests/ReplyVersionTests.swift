import Foundation
import Testing
@testable import Lasso

/// Regenerate keeps the earlier answers (‹ 1/2 ›), switching shows another, and they're saved.
@MainActor
@Suite(.serialized)
struct ReplyVersionTests {
    @Test func switchingKeepsEveryAnswer() {
        var reply = ChatMessage(role: .assistant, text: "second")
        reply.versions = [ReplyVersion(text: "first"), ReplyVersion(text: "")]
        reply.versionIndex = 1
        reply.showVersion(0)
        #expect(reply.text == "first" && reply.versionIndex == 0)
        #expect(reply.currentVersions.map(\.text) == ["first", "second"])
        reply.showVersion(1)
        #expect(reply.text == "second")
        reply.showVersion(5)
        #expect(reply.text == "second", "out of range does nothing")

        // Each answer keeps what it did (its steps) while switching.
        reply.steps = [ActivityStep(icon: "globe", text: "Searched the web", done: true)]
        reply.showVersion(0)
        #expect(reply.steps.isEmpty)
        reply.showVersion(1)
        #expect(reply.steps.map(\.text) == ["Searched the web"])
    }

    @Test func regenerateCarriesTheOldAnswerAndAnErrorIsDropped() {
        let chat = ChatController.shared
        chat.newChat()
        let id = chat.active.id
        defer { chat.close(id) }
        var answer = ChatMessage(role: .assistant, text: "The first answer")
        chat.active.messages = [ChatMessage(role: .user, text: "hi"), answer]
        chat.regenerate(answer.id)
        chat.cancelStreaming()
        var last = chat.active.messages.last!
        #expect(last.versions.map(\.text).first == "The first answer")
        #expect(last.versions.count == 2 && last.versionIndex == 1)

        // A failed answer isn't kept; the good ones before it are.
        last.text = "Couldn't reach the model."
        last.isError = true
        last.isStreaming = false
        chat.active.messages[chat.active.messages.count - 1] = last
        chat.regenerate(last.id)
        chat.cancelStreaming()
        answer = chat.active.messages.last!
        #expect(answer.versions.map(\.text) == ["The first answer", ""])
    }

    @Test func versionsAreSavedAndLoaded() {
        let c = Conversation()
        var reply = ChatMessage(role: .assistant, text: "two")
        reply.versions = [ReplyVersion(text: "one"), ReplyVersion(text: "stale")]
        reply.versionIndex = 1
        c.messages = [ChatMessage(role: .user, text: "q"), reply]
        let back = ConversationStore.rebuild(ConversationStore.snapshot(c))
        #expect(back.messages[1].versions.map(\.text) == ["one", "two"])
        #expect(back.messages[1].versionIndex == 1 && back.messages[1].text == "two")
    }
}
