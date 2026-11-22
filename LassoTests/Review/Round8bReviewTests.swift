import Foundation
import Testing
@testable import Lasso

/// Review of 95e9df6 (fixes for the round 8 review) and the wider round 8 commit f9e3774. Each test
/// fails on 95e9df6; its comment says what goes wrong for the user.
@MainActor
struct Round8bReviewTests {

    private func hasMath(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains { if case .math = $0 { return true }; return false }
    }

    // MARK: isInsideCode

    /// The fix says a ``` line inside a ~~~ block "is just code", but the raw ``` count still runs
    /// first: one ``` inside a closed ~~~ block makes the count odd, so everything after the block is
    /// "inside code". A reasoning round after it keeps its raw `<think>` in the answer.
    @Test func aBacktickLineInsideATildeBlockDoesNotHideALaterThinkTag() {
        let raw = "Fence it like this:\n~~~markdown\n```\n~~~\nDone.<think>check the tool result</think>All set."
        let split = ChatController.splitReasoning(raw)
        #expect(split.reasoning == "check the tool result", "reasoning: \"\(split.reasoning)\"")
        #expect(!split.answer.contains("<think>"), "the think tag shows in the answer: \(split.answer)")
    }

    /// A four-backtick fence showing a ``` block (the usual way to show Markdown) has three ```
    /// occurrences: odd, so prose after the closed block counts as code.
    @Test func isInsideCodeIsFalseAfterAClosedFourBacktickFence() {
        let prefix: Substring = "````markdown\n```swift\nlet x = 1\n````\nnow prose "
        #expect(!ChatController.isInsideCode(prefix))
    }

    @Test func aThinkTagAfterAFourBacktickFenceIsReasoning() {
        let raw = "Example:\n````md\n```\ncode\n````\nDone.<think>check again</think>All set."
        let split = ChatController.splitReasoning(raw)
        #expect(split.reasoning == "check again", "reasoning: \"\(split.reasoning)\"")
        #expect(!split.answer.contains("<think>"), "the think tag shows in the answer: \(split.answer)")
    }

    /// A lone backtick inside a closed fenced block (a shell line, a Markdown example) still counts as
    /// an open inline span after the block.
    @Test func aStrayBacktickInsideAClosedFenceDoesNotMakeLaterProseCode() {
        let prefix: Substring = "```\nUse a ` to start code\n```\nnow prose "
        #expect(!ChatController.isInsideCode(prefix))
    }

    // MARK: `$$` lookahead

    /// "contains a lone `$$`" also matches `$$` written in a code span on the next line, so a shell
    /// explanation becomes display math. On f9e3774 (closer must end the line) it was prose.
    @Test func dollarDollarInACodeSpanOnTheNextLineIsNotACloser() {
        let text = "In bash:\n\n$$ is the PID of the current shell. To print it,\nrun `echo $$` in a terminal."
        let blocks = MarkdownParser.parse(text)
        #expect(!hasMath(blocks), "prose rendered as math: \(blocks)")
    }

    /// While streaming, a `$$` line of prose with nothing after it yet ("reached the end") is now math:
    /// "$$ is the PID…" streams as an equation, then snaps to text when the line ends. On f9e3774 it
    /// streamed as text.
    @Test func streamingProseStartingWithDollarDollarIsNotMath() {
        let text = "In bash:\n\n$$ is the PID of the current shell, so a script can"
        let blocks = MarkdownParser.parse(text, streaming: true)
        #expect(!hasMath(blocks), "mid-stream prose shows as math: \(blocks)")
    }

    // MARK: outsideCode "x" join

    /// Joining with "x" glues a star to the code span before it, so "`char`* buf" (a C pointer type)
    /// looks like an unclosed italic: mid-stream a stray "*" trails the line. With the old " " join
    /// it was balanced.
    @Test func aStarRightAfterCodeIsNotClosedAsItalic() {
        let line = "Declare it as `char`* buf"
        #expect(StreamStabilizer.stabilize(line) == line, "stabilized to: \(StreamStabilizer.stabilize(line))")
    }
}
