import Foundation

/// Block model + parser for the Markdown that language models actually emit.
///
/// This is deliberately *not* a spec-conformant CommonMark/GFM parser. Lasso renders output from
/// everything between Apple's 3B on-device model and frontier cloud models, and the weaker the model
/// the more its Markdown drifts from spec — a table missing its separator row, a list indented three
/// spaces, a `~~~` fence, a heading with no space after the hashes. A strict parser is the wrong tool
/// there: strict parsers *reject* malformed input, which turns a model's near-miss into a wall of raw
/// pipes on screen. So the rule here is repair, not rejection — recognise the intent, render the
/// intent, and fall back to plain text only when there is no intent to recover.
///
/// Everything in this file is pure and nonisolated so the parser can be unit-tested without SwiftUI.

// MARK: - Blocks

enum MarkdownBlock: Equatable {
    case thought(String)
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([MarkdownListItem])
    /// `closed` is false for a fence the model has opened but not yet terminated — normal mid-stream,
    /// and the renderer uses it to keep the block styled as code instead of flashing to prose.
    case code(language: String?, content: String, closed: Bool)
    case table(MarkdownTable)
    case quote([MarkdownBlock])
    /// A display equation, already converted from LaTeX to Unicode text by `MathText`.
    case math(String)
    case rule
}

/// One list row. Nesting is carried per item (`depth`) rather than by nesting the blocks themselves:
/// models indent inconsistently, and a flat list with depths survives that where a tree does not.
struct MarkdownListItem: Equatable {
    /// The ordered marker as written ("1.", "2)"), or nil for a bullet.
    var marker: String?
    /// Task-list state: nil when the item isn't a checkbox.
    var checked: Bool?
    var text: String
    var depth: Int
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
    /// True for the last table in a message that is still streaming — more rows are probably coming.
    var isOpen: Bool = false

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// A "table" that carries no comparison. One column, or a single data row, is a shape the model
    /// reached for out of habit — there is nothing to scan across. The renderer shows these as
    /// label/value lines instead, which is the same information without the grid furniture.
    ///
    /// A table still being streamed is never degenerate, whatever it looks like right now: every
    /// table passes through "header only" and "one row" on its way to being finished, and downgrading
    /// those would make the grid appear, vanish and reappear as rows land.
    var isDegenerate: Bool { !isOpen && (rows.count < 2 || columnCount < 2) }

    func alignment(_ column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .leading
    }
}

// MARK: - Parser

enum MarkdownParser {
    /// Reasoning wrappers seen in the wild. `<think>` is Qwen/DeepSeek; `<thinking>` shows up in
    /// prompted chain-of-thought. In the Chat panel these are already split out upstream
    /// (`ChatController.splitReasoning`), but the capture/Ask-AI panels render raw model output.
    private static let thoughtTags = [("<think>", "</think>"), ("<thinking>", "</thinking>")]

    /// Parse `text` into renderable blocks.
    ///
    /// - Parameter streaming: true while tokens are still arriving. Enables the stability pass —
    ///   an unstable trailing line is withheld and half-typed emphasis is closed speculatively — so
    ///   the text does not jitter between shapes as it lands. Off for finished text, where every
    ///   character is final and withholding anything would silently drop content.
    static func parse(_ text: String, streaming: Bool = false) -> [MarkdownBlock] {
        let source = streaming ? StreamStabilizer.stabilize(text) : text
        var blocks: [MarkdownBlock] = []
        var cursor = source.startIndex

        while let open = nextThoughtOpen(in: source, from: cursor) {
            blocks.append(contentsOf: parsePlain(String(source[cursor..<open.range.lowerBound])))

            let thoughtStart = open.range.upperBound
            if let close = source.range(of: open.closeTag, options: .caseInsensitive,
                                        range: thoughtStart..<source.endIndex) {
                appendThought(String(source[thoughtStart..<close.lowerBound]), to: &blocks)
                cursor = close.upperBound
            } else {
                appendThought(String(source[thoughtStart..<source.endIndex]), to: &blocks)
                return blocks
            }
        }

        blocks.append(contentsOf: parsePlain(String(source[cursor..<source.endIndex])))
        if streaming, case .table(var last)? = blocks.last {
            last.isOpen = true
            blocks[blocks.count - 1] = .table(last)
        }
        return blocks
    }

    /// The earliest opening reasoning tag at or after `from`, with the closer to look for.
    private static func nextThoughtOpen(in text: String, from: String.Index)
        -> (range: Range<String.Index>, closeTag: String)? {
        thoughtTags
            .compactMap { open, close -> (Range<String.Index>, String)? in
                guard let r = text.range(of: open, options: .caseInsensitive,
                                         range: from..<text.endIndex) else { return nil }
                return (r, close)
            }
            .min { $0.0.lowerBound < $1.0.lowerBound }
            .map { (range: $0.0, closeTag: $0.1) }
    }

    private static func appendThought(_ text: String, to blocks: inout [MarkdownBlock]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { blocks.append(.thought(trimmed)) }
    }

    // MARK: Block scanning

    static func parsePlain(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(MathText.rewriteInline(joined))) }
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Display math: `\[ … \]`, `$$ … $$`, or an equation environment. Models emit these
            // constantly for anything formula-shaped, whatever the prompt asks for, and the raw
            // delimiters reaching the screen is the worst of both worlds.
            if let delims = MathText.displayOpener(line) {
                flushParagraph()
                var body: [String] = []
                var head = String(line.dropFirst(delims.open.count))
                var closed = false
                if let end = head.range(of: delims.close) {
                    body.append(String(head[..<end.lowerBound]))
                    closed = true
                    i += 1
                } else {
                    if !head.trimmingCharacters(in: .whitespaces).isEmpty { body.append(head) }
                    i += 1
                    while i < lines.count {
                        head = lines[i]
                        if let end = head.range(of: delims.close) {
                            body.append(String(head[..<end.lowerBound]))
                            closed = true
                            i += 1
                            break
                        }
                        body.append(head)
                        i += 1
                    }
                }
                _ = closed   // an unterminated block still renders what has arrived
                let rendered = MathText.render(body.joined(separator: "\n"))
                if !rendered.isEmpty { blocks.append(.math(rendered)) }
                continue
            }

            // Fenced code. Accepts ``` and ~~~, any fence length ≥ 3; the info string is the language.
            // The closing fence must use the same character, so a ``` inside a ~~~ block is content.
            if let fence = fenceMarker(line) {
                flushParagraph()
                let info = line.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                let language = info.isEmpty
                    ? nil
                    : String(info.split(whereSeparator: { $0.isWhitespace }).first ?? "")
                var code: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if let closer = fenceMarker(candidate), closer.first == fence.first,
                       closer.count >= fence.count {
                        closed = true
                        i += 1
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language,
                                    content: code.joined(separator: "\n"),
                                    closed: closed))
                continue
            }

            // Setext heading: the underline belongs to the paragraph text directly above it, so this
            // has to run before the thematic-break check (which would otherwise eat "---").
            if !paragraph.isEmpty, let level = setextLevel(line) {
                let title = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                paragraph = []
                if !title.isEmpty { blocks.append(.heading(level: level, text: title)) }
                i += 1
                continue
            }

            if isThematicBreak(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let table = scanTable(lines, from: &i) {
                flushParagraph()
                blocks.append(.table(table))
                continue
            }

            if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: level,
                                       text: MathText.rewriteInline(headingText(line, level: level))))
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    var body = String(t.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    inner.append(body)
                    i += 1
                }
                let nested = parsePlain(inner.joined(separator: "\n"))
                if !nested.isEmpty { blocks.append(.quote(nested)) }
                continue
            }

            if listMarker(raw) != nil {
                flushParagraph()
                blocks.append(.list(scanList(lines, from: &i)))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            paragraph.append(raw)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Lists

    private struct Marker {
        var indent: Int
        /// Ordered marker as written, or nil for a bullet.
        var ordered: String?
        var body: String
    }

    /// Recognise a list line and return its indent, marker and body. Indent is measured in columns
    /// (a tab counts as 4) because models mix tabs and spaces.
    private static func listMarker(_ raw: String) -> Marker? {
        var indent = 0
        var idx = raw.startIndex
        while idx < raw.endIndex, raw[idx] == " " || raw[idx] == "\t" {
            indent += raw[idx] == "\t" ? 4 : 1
            idx = raw.index(after: idx)
        }
        let rest = String(raw[idx...])
        guard !rest.isEmpty else { return nil }

        if let first = rest.first, "-*+•".contains(first) {
            let after = rest.dropFirst()
            // "- text" is a bullet; "-text" is not, and "---" was already claimed as a rule.
            guard after.first == " " || after.first == "\t" else { return nil }
            return Marker(indent: indent, ordered: nil,
                          body: String(after).trimmingCharacters(in: .whitespaces))
        }

        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let punct = after.first, punct == "." || punct == ")" else { return nil }
        let body = after.dropFirst()
        guard body.first == " " || body.first == "\t" || body.isEmpty else { return nil }
        return Marker(indent: indent, ordered: String(digits) + String(punct),
                      body: String(body).trimmingCharacters(in: .whitespaces))
    }

    /// Consume a run of list lines. Indent is mapped to depth through a stack rather than by dividing
    /// by a fixed step, so 2-space, 3-space and 4-space nesting all read correctly, and a model that
    /// switches step mid-list doesn't produce a jagged tree.
    private static func scanList(_ lines: [String], from i: inout Int) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []

        func depth(for indent: Int) -> Int {
            while let last = indents.last, indent < last { indents.removeLast() }
            if let last = indents.last {
                if indent > last { indents.append(indent) }
            } else {
                indents.append(indent)
            }
            return max(0, indents.count - 1)
        }

        while i < lines.count {
            if let marker = listMarker(lines[i]) {
                var text = marker.body
                var checked: Bool?
                // Task list: "- [ ] item" / "- [x] item".
                if text.count >= 3, text.hasPrefix("[") {
                    let box = text.dropFirst().prefix(1)
                    let afterBox = text.dropFirst(2)
                    if afterBox.hasPrefix("]"), box == " " || box.lowercased() == "x" {
                        checked = box.lowercased() == "x"
                        text = String(afterBox.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                }
                items.append(MarkdownListItem(marker: marker.ordered, checked: checked,
                                              text: MathText.rewriteInline(text),
                                              depth: depth(for: marker.indent)))
                i += 1
                continue
            }

            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // A blank line only ends the list if what follows isn't another item (a "loose" list).
            if trimmed.isEmpty {
                let next = i + 1
                guard next < lines.count, listMarker(lines[next]) != nil else { break }
                i += 1
                continue
            }

            // Indented, non-marker line: a wrapped continuation of the item above.
            let leading = lines[i].prefix(while: { $0 == " " || $0 == "\t" }).count
            guard leading >= 1, !items.isEmpty, fenceMarker(trimmed) == nil else { break }
            items[items.count - 1].text += " " + trimmed
            i += 1
        }
        return items
    }

    // MARK: Tables

    /// Consume a table starting at `i`, or return nil. Two shapes are accepted: the GFM one (header +
    /// `|---|` separator), and the common malformation where the model omits the separator entirely
    /// but every row is pipe-delimited. The second is only claimed when the rows are unambiguous —
    /// leading *and* trailing pipes on two consecutive lines — so ordinary prose containing a pipe
    /// can't be swallowed.
    private static func scanTable(_ lines: [String], from i: inout Int) -> MarkdownTable? {
        let first = lines[i].trimmingCharacters(in: .whitespaces)
        guard first.contains("|") else { return nil }

        var alignments: [MarkdownTable.Alignment] = []
        var start = i

        if i + 1 < lines.count, let aligns = separatorAlignments(lines[i + 1]) {
            alignments = aligns
            start = i + 2
        } else if isDelimitedRow(first), i + 1 < lines.count,
                  isDelimitedRow(lines[i + 1].trimmingCharacters(in: .whitespaces)),
                  separatorAlignments(lines[i + 1]) == nil {
            start = i + 1
        } else {
            return nil
        }

        let header = splitCells(first)
        var rows: [[String]] = []
        var j = start
        while j < lines.count {
            let row = lines[j].trimmingCharacters(in: .whitespaces)
            if row.isEmpty || !row.contains("|") { break }
            if separatorAlignments(row) != nil { j += 1; continue }   // a stray second separator
            rows.append(splitCells(row))
            j += 1
        }
        i = j

        // Pad ragged rows so the grid stays rectangular. Models drop or add a trailing cell often
        // enough that a renderer which trusts the header count draws a broken table.
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let paddedHeader = header + Array(repeating: "", count: max(0, columns - header.count))
        let paddedRows = rows.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
        let resolved = (0..<columns).map { c in
            c < alignments.count ? alignments[c] : MarkdownTable.Alignment.leading
        }
        return MarkdownTable(header: paddedHeader, alignments: resolved, rows: paddedRows)
    }

    /// A row that both starts and ends with a pipe and has at least two cells.
    static func isDelimitedRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.filter { $0 == "|" }.count >= 3
    }

    static func isSeparatorRow(_ line: String) -> Bool { separatorAlignments(line) != nil }

    /// Parse `|:---|---:|:--:|` into per-column alignments, or nil if the line isn't a separator.
    private static func separatorAlignments(_ raw: String) -> [MarkdownTable.Alignment]? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return nil }
        guard t.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) else { return nil }
        return splitCells(t).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    /// Split a pipe row into cells, honouring `\|` escapes (a literal pipe inside a cell).
    private static func splitCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        let sentinel = "\u{0}"
        return t.replacingOccurrences(of: "\\|", with: sentinel)
            .components(separatedBy: "|")
            .map { MathText.rewriteInline($0.replacingOccurrences(of: sentinel, with: "|")
                     .trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Line shapes

    /// The fence run ("```", "~~~~") if this line opens or closes a fenced block.
    private static func fenceMarker(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string can't contain a backtick (that would be an inline span).
        if first == "`", line.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    /// `---`, `***` or `___` on their own: a horizontal rule. Without this the dashes rendered as
    /// literal text, which is what the model's section divider used to look like on screen.
    private static func isThematicBreak(_ line: String) -> Bool {
        guard let first = line.first, first == "-" || first == "*" || first == "_" else { return false }
        let stripped = line.filter { $0 != " " }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    /// A setext underline: `===` (h1) or `---` (h2) directly under a paragraph line.
    private static func setextLevel(_ line: String) -> Int? {
        guard let first = line.first, first == "=" || first == "-" else { return nil }
        guard line.allSatisfy({ $0 == first }), line.count >= 2 else { return nil }
        return first == "=" ? 1 : 2
    }

    /// ATX heading level. The space after the hashes is required by spec but routinely omitted by
    /// small models, so `##Overview` is accepted too.
    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, line.count > hashes else { return nil }
        return hashes
    }

    private static func headingText(_ line: String, level: Int) -> String {
        var text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        // Closed ATX form: "## Title ##".
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Streaming stability

/// Keeps a partially-received message from changing shape under the reader.
///
/// Two things cause visible jitter while tokens land. A line that will become a table or a heading
/// spends its first moments looking like prose (`| Name | Size |` renders as pipes, then snaps into a
/// grid), and an emphasis run shows its own syntax until the closing marker arrives (`this is **bo`).
/// The fix used by streaming-aware renderers is to withhold the first and speculatively close the
/// second, both only on the final line, and only while streaming.
enum StreamStabilizer {
    static func stabilize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Inside an open code fence every character is literal — nothing to stabilise, and rewriting
        // code would corrupt it.
        guard !isInsideOpenFence(text) else { return text }

        var lines = text.components(separatedBy: "\n")
        // A trailing newline means the last line is already complete, so there is nothing half-typed
        // to repair — but the lines above it may still be an unresolved table.
        if !text.hasSuffix("\n"), let last = lines.last {
            if isUnstableTail(last.trimmingCharacters(in: .whitespaces)) {
                lines.removeLast()
            } else {
                lines[lines.count - 1] = closeDanglingEmphasis(last)
            }
        }
        return trimUnresolvedTable(lines).joined(separator: "\n")
    }

    /// Withhold a trailing run of pipe rows that hasn't become a table yet.
    ///
    /// Dropping only the half-typed line isn't enough: `| Model | Speed |` followed by a separator the
    /// model is still typing leaves a complete-looking header behind, and a lone header row is not a
    /// table — so it renders as prose full of pipes and then snaps into a grid a token later. That
    /// snap is the most visible jump in a streaming answer. Once the run *is* resolvable (it has a
    /// separator, or two full rows the repair path accepts) it stays, because from then on the grid
    /// only gains rows.
    private static func trimUnresolvedTable(_ lines: [String]) -> [String] {
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        var start = end
        while start > 0, looksLikeRow(lines[start - 1]) { start -= 1 }
        guard start < end else { return lines }

        let run = lines[start..<end].map { $0.trimmingCharacters(in: .whitespaces) }
        if run.contains(where: MarkdownParser.isSeparatorRow) { return lines }
        if run.count >= 2, run.allSatisfy(MarkdownParser.isDelimitedRow) { return lines }
        return Array(lines[..<start])
    }

    /// The same test `isUnstableTail` uses, so a run is judged by the rule that withheld its last line.
    private static func looksLikeRow(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        return line.hasPrefix("|") || line.filter { $0 == "|" }.count >= 2
    }

    /// A line that hasn't yet earned its final shape: a pipe row (no separator has arrived, so it
    /// would draw as prose), a bare heading or fence marker, or the start of a rule.
    private static func isUnstableTail(_ line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasPrefix("|") || line.filter({ $0 == "|" }).count >= 2 { return true }
        if line.allSatisfy({ $0 == "#" }) { return true }
        if line.allSatisfy({ $0 == "`" }) || line.allSatisfy({ $0 == "~" }) { return true }
        if line == "\\" || line == "\\[" || line == "$" || line == "$$" { return true }
        if line.count <= 2, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return true }
        return false
    }

    private static func isInsideOpenFence(_ text: String) -> Bool {
        var open: Character?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first == "`" || first == "~" else { continue }
            guard line.prefix(while: { $0 == first }).count >= 3 else { continue }
            if let current = open {
                if current == first { open = nil }
            } else {
                open = first
            }
        }
        return open != nil
    }

    /// Balance the inline markers on a half-typed line: drop a dangling opener sitting at the very
    /// end, then close whatever is still open so `**bo` reads as bold "bo" rather than as asterisks.
    /// Underscores are deliberately left alone — `snake_case` identifiers are far more common in this
    /// app's output than `_emphasis_`.
    static func closeDanglingEmphasis(_ line: String) -> String {
        var work = line
        if isBalanced(work) { return work }

        // Strip a trailing marker run — the opener of something not yet typed.
        let trailing = work.reversed().prefix(while: { $0 == "*" || $0 == "~" || $0 == "`" }).count
        if trailing > 0 {
            let candidate = String(work.dropLast(trailing))
            if isBalanced(candidate) { return candidate }
            work = candidate
        }

        var closers = ""
        if count(of: "`", in: work) % 2 == 1 { closers += "`" }
        if count(of: "~~", in: work) % 2 == 1 { closers += "~~" }
        if count(of: "**", in: work) % 2 == 1 { closers += "**" }
        else if singleAsterisks(in: work) % 2 == 1 { closers += "*" }
        return work + closers
    }

    private static func isBalanced(_ s: String) -> Bool {
        count(of: "`", in: s) % 2 == 0
            && count(of: "~~", in: s) % 2 == 0
            && count(of: "**", in: s) % 2 == 0
            && singleAsterisks(in: s) % 2 == 0
    }

    private static func count(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var index = text.startIndex
        while let r = text.range(of: needle, range: index..<text.endIndex) {
            n += 1
            index = r.upperBound
        }
        return n
    }

    /// Asterisks that aren't part of a `**` pair — the single-emphasis delimiters.
    private static func singleAsterisks(in text: String) -> Int {
        var n = 0
        var run = 0
        for c in text {
            if c == "*" { run += 1 } else { n += run % 2; run = 0 }
        }
        return n + run % 2
    }
}
