import Testing
import CoreGraphics
@testable import Lasso

struct LassoTests {
    @Test func rectBetweenNormalizesPoints() {
        let r = CGRect.between(CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8))
        #expect(r.origin.x == 4)
        #expect(r.origin.y == 8)
        #expect(r.width == 6)
        #expect(r.height == 12)
    }

    @Test func dataDetectorFindsURL() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Visit https://example.com for details.")
        #expect(items.contains { $0.kind == .url })
    }

    @Test func dataDetectorFindsPhone() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Call +1 (415) 555-0132 today.")
        #expect(items.contains { $0.kind == .phone })
    }

    @MainActor
    @Test func registryOrdersByPriority() {
        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        // ColorPicker (priority 50) is relevant to any selection; OCRCopy needs text.
        #expect(!registry.actions.isEmpty)
    }

    // MARK: - ChatContextBuilder: two-track memory (Phase 2)

    /// A user turn helper for building history.
    private func userTurn(_ text: String) -> ChatContextBuilder.HistoryTurn {
        .init(role: .user, text: text, imageBase64: nil)
    }

    /// The core bug fix: durable facts must survive even when the topic trace overflows its clamp and
    /// gets tail-trimmed. A fact from turn 1 ("name is Sam") must still appear in the sent context.
    @Test func durableFactsSurviveTopicOverflow() {
        var builder = ChatContextBuilder()
        builder.budget.maxSummaryChars = 100   // tiny topic reserve to force the clamp
        builder.budget.maxDurableChars = 800

        let memory = ConversationMemory(
            durableFacts: "- The user's name is Sam.\n- Sam is building Lasso, a macOS menu-bar app.",
            // Long topic trace whose head ("apples") will be clamped away; only the tail survives.
            topicTrace: "Discussed apples. " + String(repeating: "Discussed oranges in detail. ", count: 20))

        // Need overflow for memory to be injected at all.
        let history = (1...8).map { userTurn("msg \($0)") }

        let out = builder.build(systemPrompt: "SYS", memory: memory, history: history,
                                currentUserText: "now what?", currentImageBase64: nil)

        let memoryBlock = out.turns.first { $0.role == .system && $0.text.contains("Sam") }
        #expect(memoryBlock != nil)
        #expect(memoryBlock?.text.contains("name is Sam") == true)
        // The oldest topic word got clamped off, proving the topic track WAS trimmed...
        #expect(memoryBlock?.text.contains("Discussed apples") == false)
        // ...yet the durable facts (a different, protected track) survived intact.
        #expect(memoryBlock?.text.contains("building Lasso") == true)
    }

    /// Short conversation, no overflow → no memory/summary block injected (behaves like Phase 1 did
    /// before any compression).
    @Test func shortConversationInjectsNoMemoryBlock() {
        let builder = ChatContextBuilder()   // recentTurns = 6 by default
        let memory = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "talked about apples")
        let history = (1...4).map { userTurn("msg \($0)") }   // under the recent window → no overflow

        let out = builder.build(systemPrompt: "SYS", memory: memory, history: history,
                                currentUserText: "hi", currentImageBase64: nil)

        #expect(out.didCompress == false)
        // Only the system prompt is a system turn; no injected memory block.
        let systemTurns = out.turns.filter { $0.role == .system }
        #expect(systemTurns.count == 1)
        #expect(systemTurns.first?.text == "SYS")
    }

    /// A malformed (label-less) model response must fall back without data loss: prior durable facts
    /// are preserved, and the whole output becomes the new topic trace.
    @Test func malformedSummaryFallsBackWithoutDataLoss() {
        let prior = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "old topics")
        let sloppy = "We chatted about deployment and then about testing strategy."   // no FACTS/TOPICS

        let parsed = ChatController.parseMemory(from: sloppy, prior: prior)
        #expect(parsed.durableFacts == "- name is Sam")          // protected facts preserved
        #expect(parsed.topicTrace == sloppy)                    // output salvaged as topic notes
    }

    /// Happy path: well-formed FACTS/TOPICS output parses into both tracks.
    @Test func wellFormedSummaryParsesBothTracks() {
        let prior = ConversationMemory()
        let output = """
        FACTS:
        - The user's name is Sam.
        - Sam is building Lasso.
        TOPICS:
        Currently discussing the chat context pipeline.
        """
        let parsed = ChatController.parseMemory(from: output, prior: prior)
        #expect(parsed.durableFacts.contains("name is Sam"))
        #expect(parsed.durableFacts.contains("building Lasso"))
        #expect(parsed.topicTrace.contains("chat context pipeline"))
        #expect(!parsed.topicTrace.contains("FACTS"))
    }

    /// Partial output (only TOPICS) keeps prior facts forward rather than wiping them.
    @Test func partialSummaryPreservesPriorFacts() {
        let prior = ConversationMemory(durableFacts: "- name is Sam", topicTrace: "old")
        let parsed = ChatController.parseMemory(from: "TOPICS:\nnew topic only", prior: prior)
        #expect(parsed.durableFacts == "- name is Sam")
        #expect(parsed.topicTrace == "new topic only")
    }
}
