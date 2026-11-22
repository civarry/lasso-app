import Foundation
import Testing
@testable import Lasso

/// QA round 8: rendering regressions around the round 1-2 Markdown fixes. Each test fails on the code as
/// it stands.
@MainActor
@Suite
struct MarkdownRound8Tests {

    // MARK: Streaming emphasis inside code spans

    /// `closeDanglingEmphasis` counts asterisks inside `inline code`. A Python answer mid-stream
    /// ("Pass `**kwargs` to the") gets a stray `**` stuck on the end of the line until it finishes.
    @Test func streamingLineWithKwargsInCodeGetsNoStrayAsterisks() {
        let line = "Pass `**kwargs` to the"
        #expect(StreamStabilizer.stabilize(line) == line, "stabilized to: \(StreamStabilizer.stabilize(line))")
    }

    @Test func streamingLineWithArgsInCodeGetsNoStrayAsterisk() {
        let line = "Use `*args` when the number of"
        #expect(StreamStabilizer.stabilize(line) == line, "stabilized to: \(StreamStabilizer.stabilize(line))")
    }

    // MARK: `$$` that isn't display math

    /// A line starting with `$$` opens display math, and with no `$$` after it on that line the parser
    /// keeps eating lines until one has `$$` anywhere. Restaurant price tiers turn into one garbled
    /// "equation".
    @Test func priceTiersAreNotDisplayMath() {
        let text = "Price guide:\n\n$ cheap eats\n$$ mid-range, about 20 dollars\n$$$ fine dining\n\nEnjoy!"
        let blocks = MarkdownParser.parse(text)
        let math = blocks.filter { if case .math = $0 { return true }; return false }
        #expect(math.isEmpty, "price tiers parsed as math: \(blocks)")
    }

    /// The same run swallows a code block below it: the fence's opening line becomes part of the
    /// "equation" and the code is lost.
    @Test func anUnclosedDollarLineDoesNotSwallowTheCodeBelow() {
        let text = "$$ expands to the shell's process ID.\n\n```bash\necho $$\n```"
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.contains(.code(language: "bash", content: "echo $$", closed: true)), "blocks: \(blocks)")
    }

    // MARK: Reasoning tags inside ~~~ fences

    /// Round 2 made a `<think>` inside code part of the answer, but `isInsideCode` only counts ``` fences;
    /// the parser also accepts ~~~. A tag shown in a ~~~ block is pulled out as the model's thinking.
    @Test func thinkTagInsideATildeFenceIsAnswerText() {
        let raw = "Qwen wraps its reasoning like this:\n~~~\n<think>plan the answer</think>\n~~~\nThat's all."
        let split = ChatController.splitReasoning(raw)
        #expect(split.reasoning.isEmpty, "a tag inside ~~~ became reasoning: \"\(split.reasoning)\"")
        #expect(split.answer.contains("<think>"), "answer lost the example: \(split.answer)")
    }

    @Test func thinkTagInsideATildeFenceRendersAsCode() {
        let raw = "Example:\n~~~\n<think>plan</think>\n~~~"
        let blocks = MarkdownParser.parse(raw)
        let thoughts = blocks.filter { if case .thought = $0 { return true }; return false }
        #expect(thoughts.isEmpty, "blocks: \(blocks)")
    }
}
