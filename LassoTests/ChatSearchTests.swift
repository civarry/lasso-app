import Foundation
import Testing
@testable import Lasso

@MainActor
struct ChatSearchTests {
    func chat(_ title: String, _ texts: [String]) -> Conversation {
        let c = Conversation()
        c.autoTitle = title
        c.messages = texts.enumerated().map { ChatMessage(role: $0.offset % 2 == 0 ? .user : .assistant, text: $0.element) }
        return c
    }

    @Test func titleMatchesComeFirstThenMessages() {
        let a = chat("Adobo recipe", ["how do I cook adobo?", "Brown the chicken."])
        let b = chat("Weekend plans", ["what should I cook?", "Try a chicken adobo with rice and egg on the side."])
        let empty = Conversation()
        let results = ChatSearch.results("Adobo", in: [b, a, empty], activeID: a.id)
        #expect(results.map(\.title) == ["Adobo recipe", "Weekend plans"])
        #expect(results[0].snippet == nil && results[0].isActive)
        #expect(results[1].snippet?.contains("adobo") == true)
    }

    @Test func everyWordMustMatchAndAccentsDontMatter() {
        let c = chat("Trip", ["Café near the station", "It opens at 7."])
        #expect(ChatSearch.results("cafe station", in: [c], activeID: UUID()).count == 1)
        #expect(ChatSearch.results("cafe airport", in: [c], activeID: UUID()).isEmpty)
        #expect(ChatSearch.results("", in: [c, Conversation()], activeID: UUID()).count == 1, "empty query: every chat with messages")
    }

    @Test func aSnippetIsShortAndAroundTheWord() {
        let long = String(repeating: "word ", count: 40) + "needle " + String(repeating: "tail ", count: 40)
        let s = ChatSearch.snippet(long, around: "needle")
        #expect(s.contains("needle") && s.hasPrefix("…") && s.hasSuffix("…") && s.count <= 92)
    }
}
