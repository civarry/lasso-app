import AppKit
import Foundation
import Testing
@testable import Lasso

/// Regression: Markdown rendering, reasoning tags, math, and paste. Each test is a bug a QA pass found;
/// it fails without its fix.
@MainActor
@Suite(.serialized)
struct MarkdownRegressionTests {

    private func codeContent(_ blocks: [MarkdownBlock]) -> String? {
        for case .code(_, let c, _) in blocks { return c }
        return nil
    }

    // 1. Inline math rewrite runs inside inline code spans.
    @Test func dollarInsideInlineCodeSurvives() {
        let b = MarkdownParser.parse("Set `$JAVA_HOME` and `$PATH` first.")
                guard case .paragraph(let p)? = b.first else { Issue.record("no paragraph"); return }
        #expect(p.contains("`$JAVA_HOME`") && p.contains("`$PATH`"), "got: \(p)")
    }

    @Test func regexEscapedParensInsideInlineCodeSurvive() {
        let b = MarkdownParser.parse("Use the regex `\\(\\d+\\)` to match a number in parentheses.")
                guard case .paragraph(let p)? = b.first else { Issue.record("no paragraph"); return }
        #expect(p.contains("`\\(\\d+\\)`"), "got: \(p)")
    }

    @Test func dollarInsideFencelessTableCodeCell() {
        let t = "| Var | Meaning |\n|---|---|\n| `$HOME_DIR` | home |\n| `$PWD` | cwd |"
                guard case .table(let table)? = MarkdownParser.parse(t).first else { Issue.record("no table"); return }
        #expect(table.rows[0][0] == "`$HOME_DIR`", "got \(table.rows[0][0])")
    }

    // 2. A fence inside a numbered step keeps the list indentation in the code (Copy/Run break).
    @Test func fenceInsideListItemIsDedented() {
        let text = "1. Save this:\n   ```python\n   def f():\n       return 1\n   ```\n2. Run it."
        let b = MarkdownParser.parse(text)
        let code = codeContent(b) ?? "<none>"
                #expect(code == "def f():\n    return 1", "code keeps list indent: \(code.debugDescription)")
    }

    // 3. CRLF text: tables, rules and fence language break.
    @Test func crlfTable() {
        let text = "| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n| 3 | 4 |\r\n"
        let b = MarkdownParser.parse(text)
                #expect(b.contains { if case .table = $0 { true } else { false } }, "no table from CRLF text")
    }

    @Test func crlfFenceLanguageAndRule() {
        let b = MarkdownParser.parse("Intro\r\n\r\n---\r\n\r\n```swift\r\nlet x = 1\r\n```\r\n")
                #expect(b.contains(.rule), "no rule from CRLF ---")
        #expect(b.contains { if case .code("swift", _, _) = $0 { true } else { false } }, "language not 'swift'")
    }

    // 4. Stabiliser closes a "* " bullet marker / multiplication as emphasis: stray asterisk mid-stream.
    @Test func streamingStarBulletGetsNoStrayAsterisk() {
        let b = MarkdownParser.parse("Options:\n* first option\n* second opt", streaming: true)
                guard case .list(let items)? = b.last else { Issue.record("no list"); return }
        #expect(items.last?.text == "second opt", "got \(items.last?.text ?? "")")
    }

    @Test func streamingMultiplicationGetsNoStrayAsterisk() {
        let b = MarkdownParser.parse("So the area is 4 * 5", streaming: true)
                #expect(b == [.paragraph("So the area is 4 * 5")])
    }

    // 5. "## Learning C#" loses the #.
    @Test func headingEndingInSharpKeepsIt() {
        let b = MarkdownParser.parse("## Learning C#\n\n### Why F#")
                #expect(b == [.heading(level: 2, text: "Learning C#"), .heading(level: 3, text: "Why F#")])
    }

    // 6. Display math with text after the closer on the same line drops that text.
    @Test func textAfterDisplayMathCloserIsKept() {
        let b = MarkdownParser.parse("$$E = mc^2$$ where E is energy.")
                let flat = b.map { "\($0)" }.joined()
        #expect(flat.contains("where E is energy"), "text after $$ dropped: \(b)")
    }

    // 7. Chat splitReasoning: a `<think>` mentioned in inline code swallows the rest of the answer.
    @Test func thinkTagInInlineCodeIsNotReasoning() {
        let raw = "DeepSeek wraps its reasoning in a `<think>` block. Strip it before display.\n\nThat's all."
        let split = ChatController.splitReasoning(raw)
                #expect(split.answer.contains("That's all."), "answer truncated: \(split.answer.debugDescription)")
        #expect(split.reasoning.isEmpty)
        #expect(!split.thinking)
    }

    @Test func thinkTagInCodeFenceIsNotThought() {
        let text = "Example output:\n```\n<think>\nplan\n</think>\nanswer\n```\nDone."
        let b = MarkdownParser.parse(text)
                #expect(!b.contains { if case .thought = $0 { true } else { false } }, "fence content parsed as Thought")
    }


    // 9. Performance: a 50 KB reply, parsed once finished and once per streamed chunk.
    @Test func parse50KBTiming() {
        var s = ""
        var n = 0
        while s.utf8.count < 50_000 {
            n += 1
            s += "## Section \(n)\n\nSome **bold** text with `code` and $x^2$ math, line \(n).\n\n"
            s += "- item one\n  - nested item\n- item two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet v = \(n)\n```\n\n"
        }
        let clock = ContinuousClock()
        let once = clock.measure { _ = MarkdownParser.parse(s) }
        let streamOnce = clock.measure { _ = MarkdownParser.parse(s, streaming: true) }
        // A long-paragraph reply with no newlines at all.
        let longLine = String(repeating: "word **b** `c` $5 ", count: 3000)
        let ll = clock.measure { _ = MarkdownParser.parse(longLine, streaming: true) }
                #expect(once < .milliseconds(200))
        #expect(ll < .milliseconds(200))
    }

    // 10. ⌘V with text AND a PDF/image flavor (Pages, Word, Numbers copies) attaches a picture.
    @Test func richTextCopyAlsoReadsAsImage() {
        let pb = NSPasteboard(name: NSPasteboard.Name("qa.lasso.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let pdf = NSMutableData()
        let consumer = CGDataConsumer(data: pdf as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 100, height: 40)
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let item = NSPasteboardItem()
        item.setString("a paragraph copied from Pages", forType: .string)
        item.setData(pdf as Data, forType: .pdf)
        pb.writeObjects([item])
        #expect(ChatController.clipboardImage(pb) == nil, "a text copy carrying a PDF flavor reads as an image")
    }
}
