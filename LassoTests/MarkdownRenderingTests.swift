import Testing
import Foundation
@testable import Lasso

/// The Markdown parser, exercised with the shapes models actually emit rather than with spec
/// examples. Every case here is either output a model produced (a table with no separator row, a
/// three-space nested bullet, a `~~~` fence) or a mid-stream frame the user would otherwise see
/// flicker. The parser's contract is repair, not conformance, so these are the tests that matter.
struct MarkdownRenderingTests {

    // MARK: - Helpers

    private func blocks(_ text: String, streaming: Bool = false) -> [MarkdownBlock] {
        MarkdownParser.parse(text, streaming: streaming)
    }

    private func table(_ text: String) -> MarkdownTable? {
        for case .table(let t) in blocks(text) { return t }
        return nil
    }

    private func items(_ text: String) -> [MarkdownListItem] {
        for case .list(let i) in blocks(text) { return i }
        return []
    }

    // MARK: - Structure the old parser dropped

    /// A section divider used to render as three literal dashes in the middle of the answer.
    @Test func thematicBreakIsARule() {
        #expect(blocks("Before\n\n---\n\nAfter") == [.paragraph("Before"), .rule, .paragraph("After")])
        #expect(blocks("***").contains(.rule))
        #expect(blocks("___").contains(.rule))
    }

    /// A dash run directly under a line is a setext heading, not a rule.
    @Test func setextUnderlineBecomesAHeading() {
        #expect(blocks("Overview\n---\nBody") == [.heading(level: 2, text: "Overview"), .paragraph("Body")])
        #expect(blocks("Title\n===") == [.heading(level: 1, text: "Title")])
    }

    @Test func blockquoteNests() {
        let parsed = blocks("> quoted **text**\n> - item")
        guard case .quote(let inner) = parsed.first else {
            Issue.record("expected a quote, got \(parsed)")
            return
        }
        #expect(inner.first == .paragraph("quoted **text**"))
        #expect(inner.count == 2)
    }

    /// Sub-bullets used to flatten to one level, which silently destroyed the model's hierarchy.
    @Test func nestedBulletsKeepTheirDepth() {
        let parsed = items("- top\n  - child\n    - grandchild\n- second")
        #expect(parsed.map(\.depth) == [0, 1, 2, 0])
        #expect(parsed.map(\.text) == ["top", "child", "grandchild", "second"])
    }

    /// Indentation step varies by model (2, 3 or 4 spaces). Depth comes from the relative order of
    /// indents, so any consistent step reads the same.
    @Test func nestingToleratesAnyIndentStep() {
        #expect(items("- a\n   - b").map(\.depth) == [0, 1])
        #expect(items("* a\n    * b").map(\.depth) == [0, 1])
    }

    @Test func taskListItemsCarryCheckedState() {
        let parsed = items("- [ ] todo\n- [x] done")
        #expect(parsed.map(\.checked) == [false, true])
        #expect(parsed.map(\.text) == ["todo", "done"])
    }

    @Test func orderedMarkersSurviveAndParensWork() {
        #expect(items("1. first\n2) second").map(\.marker) == ["1.", "2)"])
    }

    /// A wrapped list item used to break out of the list and become its own paragraph.
    @Test func indentedContinuationJoinsTheItemAbove() {
        let parsed = items("- first line\n  wrapped tail\n- second")
        #expect(parsed.count == 2)
        #expect(parsed[0].text == "first line wrapped tail")
    }

    @Test func tildeFencesAreCode() {
        let parsed = blocks("~~~python\nprint(1)\n~~~")
        #expect(parsed == [.code(language: "python", content: "print(1)", closed: true)])
    }

    @Test func headingWithoutASpaceStillParses() {
        #expect(blocks("##Overview") == [.heading(level: 2, text: "Overview")])
        #expect(blocks("## Closed ##") == [.heading(level: 2, text: "Closed")])
    }

    // MARK: - Tables

    @Test func standardTableParsesWithAlignment() {
        let t = table("""
        | Model | Size |
        |:------|-----:|
        | a     | 3B   |
        | b     | 7B   |
        """)
        #expect(t?.header == ["Model", "Size"])
        #expect(t?.alignments == [.leading, .trailing])
        #expect(t?.rows.count == 2)
        #expect(t?.isDegenerate == false)
    }

    /// Small models routinely forget the `|---|` row. Without repair the whole table rendered as
    /// paragraphs full of pipes.
    @Test func tableWithNoSeparatorRowIsRecovered() {
        let t = table("""
        | Model | Size |
        | a | 3B |
        | b | 7B |
        """)
        #expect(t?.header == ["Model", "Size"])
        #expect(t?.rows == [["a", "3B"], ["b", "7B"]])
    }

    /// Ragged rows are common and must not shift the grid.
    @Test func raggedRowsArePaddedToTheColumnCount() {
        let t = table("""
        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        | 1 | 2 | 3 | 4 |
        """)
        #expect(t?.columnCount == 4)
        #expect(t?.rows[0] == ["1", "2", "", ""])
    }

    @Test func escapedPipeStaysInsideItsCell() {
        let t = table("""
        | Op | Meaning |
        |----|---------|
        | a \\| b | or |
        """)
        #expect(t?.rows.first == ["a | b", "or"])
    }

    /// The renderer downgrades these to label/value lines instead of drawing a grid — the single
    /// biggest source of "why is this a table?" in day-to-day output.
    @Test func singleRowAndSingleColumnTablesAreDegenerate() {
        #expect(table("| Name | Value |\n|---|---|\n| port | 8080 |")?.isDegenerate == true)
        #expect(table("| Item |\n|------|\n| one |\n| two |")?.isDegenerate == true)
    }

    /// Prose that happens to contain a pipe must not be mistaken for a table.
    @Test func proseWithAPipeIsNotATable() {
        #expect(table("Run `ls | grep swift` to filter the list.") == nil)
    }

    // MARK: - Streaming stability

    /// Half-typed emphasis showed its own syntax until the closing marker arrived.
    @Test func danglingEmphasisIsClosedWhileStreaming() {
        #expect(blocks("this is **bo", streaming: true) == [.paragraph("this is **bo**")])
        #expect(blocks("a `cod", streaming: true) == [.paragraph("a `cod`")])
    }

    /// A marker with nothing after it yet is dropped rather than closed, so no empty bold flashes.
    @Test func trailingOpenerIsDroppedNotClosed() {
        #expect(blocks("ready **", streaming: true) == [.paragraph("ready")])
    }

    /// Balanced text must survive the stabiliser untouched.
    @Test func completedEmphasisIsLeftAlone() {
        #expect(blocks("this is **bold**", streaming: true) == [.paragraph("this is **bold**")])
    }

    /// The first line of a table looks like prose until its separator lands; showing it and then
    /// snapping to a grid is the jitter users notice most.
    @Test func partialTableRowIsWithheldWhileStreaming() {
        #expect(blocks("Here:\n\n| Model | Size", streaming: true) == [.paragraph("Here:")])
    }

    /// The header row completes before its separator does. Dropping only the half-typed separator
    /// would leave a lone pipe row behind, which renders as prose and then snaps into a grid.
    @Test func headerAwaitingItsSeparatorIsAlsoWithheld() {
        #expect(blocks("Here:\n\n| Model | Speed |\n|--", streaming: true) == [.paragraph("Here:")])
        #expect(blocks("Here:\n\n| Model | Speed |\n", streaming: true) == [.paragraph("Here:")])
    }

    /// Once the separator lands the grid is established, so it stays put and only gains rows — even
    /// while it is still empty or has a single row, which would otherwise read as degenerate.
    @Test func establishedTableStaysAGridWhileItFills() {
        for frame in ["| Model | Speed |\n|---|---|\n",
                      "| Model | Speed |\n|---|---|\n| qwen3 | 96 |\n"] {
            guard case .table(let t)? = blocks(frame, streaming: true).first else {
                Issue.record("expected a table for frame: \(frame)")
                continue
            }
            #expect(t.isOpen)
            #expect(!t.isDegenerate)
            #expect(t.header == ["Model", "Speed"])
        }
    }

    /// …and the same single-row table, once finished, is downgraded as before.
    @Test func theSameTableIsDegenerateOnceFinished() {
        #expect(table("| Model | Speed |\n|---|---|\n| qwen3 | 96 |")?.isDegenerate == true)
    }

    /// …but once the stream is done, nothing may be withheld: the text is final and must render.
    @Test func nothingIsWithheldOnceFinished() {
        #expect(!blocks("Here:\n\n| Model | Size").isEmpty)
        #expect(blocks("Here:\n\n| Model | Size").count == 2)
    }

    /// Inside an open fence every character is literal, so the stabiliser must not rewrite it.
    @Test func codeContentIsNotStabilised() {
        let parsed = blocks("```swift\nlet x = a * b * c\nlet y = **", streaming: true)
        #expect(parsed == [.code(language: "swift", content: "let x = a * b * c\nlet y = **", closed: false)])
    }

    @Test func unterminatedFenceStillRendersAsCode() {
        let parsed = blocks("```swift\nlet x = 1")
        #expect(parsed == [.code(language: "swift", content: "let x = 1", closed: false)])
    }

    // MARK: - Reasoning wrappers

    @Test func thinkingTagVariantsBecomeThoughtBlocks() {
        #expect(blocks("<thinking>hmm</thinking>Answer")
            == [.thought("hmm"), .paragraph("Answer")])
        #expect(blocks("<think>hmm</think>Answer")
            == [.thought("hmm"), .paragraph("Answer")])
    }

    // MARK: - The format contract

    /// The rule the whole change turns on: a table has an admission test, and the two shapes that
    /// caused the random tables (a single thing's properties, a step list) are named as exclusions.
    @MainActor
    @Test func fullPolicyGivesTablesAnAdmissionTest() {
        let rules = ChatController.formatRules(.full)
        #expect(rules.contains("two or more things across two or more shared attributes"))
        #expect(rules.lowercased().contains("default to prose"))
        #expect(rules.contains("four columns"))
        #expect(rules.contains("language tag"))
    }

    /// The app can't draw these, so the model must be told not to emit them — otherwise the syntax
    /// itself lands on screen.
    @MainActor
    @Test func fullPolicyNamesWhatTheSurfaceCannotRender() {
        let rules = ChatController.formatRules(.full).lowercased()
        for unsupported in ["latex", "html", "footnotes"] {
            #expect(rules.contains(unsupported), "policy should rule out \(unsupported)")
        }
    }

    /// A ~2K-token window can't spend 140 words on formatting, so the compact form has to stay short
    /// and simply ban the constructs those models get wrong.
    @MainActor
    @Test func compactPolicyIsShortAndBansTables() {
        let rules = ChatController.formatRules(.compact)
        #expect(rules.split(separator: " ").count < 45)
        #expect(rules.lowercased().contains("no tables"))
        #expect(rules.count < ChatController.formatRules(.full).count / 3)
    }

    @MainActor
    @Test func systemPromptCarriesThePolicy() {
        #expect(ChatController.systemPrompt.contains(ChatController.formatRules(.full)))
    }
}

