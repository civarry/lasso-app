import Foundation
import Testing
@testable import Lasso

/// Speed budgets for work the chat does on the main thread while you type or scroll. Each budget is
/// several times what it takes today on an M-series Mac, so a test fails on a real slowdown (something
/// went quadratic), not on a busy machine.
@MainActor
struct ChatPerformanceTests {
    func time(_ work: () -> Void) -> Duration { ContinuousClock().measure(work) }

    static let longReply: String = {
        var parts: [String] = []
        for i in 0..<120 {
            parts.append("## Part \(i)\n\nSome **bold** text with `code`, a [link](https://example.com) and $x^2$.")
            parts.append("- item one\n- item two\n  - nested")
            parts.append("```swift\nlet value\(i) = compute(\(i))\nprint(value\(i))\n```")
            parts.append("| a | b |\n|---|---|\n| 1 | 2 |")
        }
        return parts.joined(separator: "\n\n")
    }()

    @Test func parsingALongReplyStaysFast() {
        let text = Self.longReply
        #expect(text.utf8.count > 20_000)
        #expect(time { _ = MarkdownParser.parse(text) } < .milliseconds(250), "finished parse")
        // Streaming re-parses on every publish (about 20 a second): it must stay well under a frame budget.
        #expect(time { _ = MarkdownParser.parse(text, streaming: true) } < .milliseconds(250), "streaming parse")
    }

    @Test func searchingManyChatsStaysFast() {
        var chats: [Conversation] = []
        for c in 0..<300 {
            let conversation = Conversation()
            conversation.autoTitle = "Chat \(c)"
            conversation.messages = (0..<40).map { m in
                ChatMessage(role: m % 2 == 0 ? .user : .assistant,
                            text: "Message \(m) of chat \(c) about cooking, travel, Python and the weekend plans.")
            }
            chats.append(conversation)
        }
        var index: [ChatSearch.Entry] = []
        #expect(time { index = ChatSearch.index(chats) } < .milliseconds(1_500), "opening the search")
        // Per keystroke, on 12,000 messages.
        #expect(time { _ = ChatSearch.results("python weekend", in: index, activeID: UUID()) } < .milliseconds(100))
        #expect(time { _ = ChatSearch.results("zzz-not-there", in: index, activeID: UUID()) } < .milliseconds(150))
    }

    @Test func buildingTheModelsContextStaysFast() {
        let history: [ChatContextBuilder.HistoryTurn] = (0..<400).map { i in
            .init(role: i % 2 == 0 ? .user : .assistant, text: String(repeating: "word ", count: 200))
        }
        let builder = ChatContextBuilder()
        #expect(time {
            _ = builder.build(systemPrompt: "sys", memory: ConversationMemory(), history: history,
                              currentUserText: "next question", currentImageBase64s: [])
        } < .milliseconds(150))
        let messages = (0..<400).map { i in ChatMessage(role: i % 2 == 0 ? .user : .assistant, text: "turn \(i)") }
        #expect(time { _ = ChatController.historyTurns(from: messages[...]) } < .milliseconds(50))
        #expect(time { _ = ChatController.hermesHistory(from: messages[...]) } < .milliseconds(50))
    }
}
