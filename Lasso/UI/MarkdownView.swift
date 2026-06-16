import SwiftUI

/// Lightweight, dependency-free Markdown block renderer for AI output. Handles the constructs local
/// models commonly emit: tables (→ SwiftUI Grid), headings, bullet/numbered lists, fenced code, and
/// paragraphs (inline **bold**/*italic*/`code`/links via AttributedString). Anything unrecognized
/// falls back to plain paragraph text, and partial Markdown mid-stream renders best-effort.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 15
    /// Whether text in this render is drag-selectable. Off in the Chat panel, where selectable text
    /// intercepts clicks meant for nearby controls (the Activity disclosure) — chat uses a Copy button instead.
    var selectable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .thought(let s):
            ThoughtDisclosure(text: s, fontSize: fontSize)

        case .paragraph(let s):
            inline(s).font(.system(size: fontSize))

        case .heading(let level, let s):
            inline(s).font(.system(size: fontSize + CGFloat(max(0, 4 - level)) * 2 + 2, weight: .bold))
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.system(size: fontSize))
                        inline(item).font(.system(size: fontSize))
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(pair.0).font(.system(size: fontSize, weight: .medium).monospacedDigit())
                        inline(pair.1).font(.system(size: fontSize))
                    }
                }
            }

        case .code(let s):
            HScroll {
                Text(s)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .textSelectable(selectable)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))

        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    private func inline(_ s: String) -> Text {
        Text(AttributedString.fromMarkdown(s))
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        return HScroll {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        cell(c < header.count ? header[c] : "", weight: .semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { c in
                            cell(c < row.count ? row[c] : "", weight: .regular)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
    }

    private func cell(_ s: String, weight: Font.Weight) -> some View {
        Text(AttributedString.fromMarkdown(s))
            .font(.system(size: fontSize - 1, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// `.textSelection(.enabled/.disabled)` can't go in a ternary (different concrete types), so
    /// branch via @ViewBuilder.
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

// MARK: - Horizontal scroll with an overflow affordance

/// Wraps wide content (tables, code) in a horizontal scroll view that shows the scrollbar and a
/// right-edge fade *only when the content actually overflows* — a clear "there's more →" hint so
/// users don't have to discover Shift-scroll. Trackpad horizontal swipe works as usual.
private struct HScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var overflowing: Bool { contentWidth > viewportWidth + 1 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .overlay(alignment: .trailing) {
            if overflowing {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor).opacity(0),
                             Color(nsColor: .windowBackgroundColor)],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 26)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Collapsible model thoughts

private struct ThoughtDisclosure: View {
    let text: String
    let fontSize: CGFloat
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            MarkdownView(text: text, fontSize: max(11, fontSize - 1))
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
                .padding(.top, 4)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.secondary.opacity(0.28))
                        .frame(width: 1)
                        .padding(.vertical, 3)
                }
        } label: {
            Label("Thought", systemImage: "brain.head.profile")
                .font(.system(size: max(11, fontSize - 2), weight: .medium))
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
    }
}

// MARK: - Parser

enum MarkdownBlock {
    case thought(String)
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered([(String, String)])
    case code(String)
    case table(header: [String], rows: [[String]])
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var cursor = text.startIndex

        while let open = text.range(of: "<think>", options: .caseInsensitive,
                                    range: cursor..<text.endIndex) {
            blocks.append(contentsOf: parsePlain(String(text[cursor..<open.lowerBound])))

            let thoughtStart = open.upperBound
            if let close = text.range(of: "</think>", options: .caseInsensitive,
                                      range: thoughtStart..<text.endIndex) {
                appendThought(String(text[thoughtStart..<close.lowerBound]), to: &blocks)
                cursor = close.upperBound
            } else {
                appendThought(String(text[thoughtStart..<text.endIndex]), to: &blocks)
                cursor = text.endIndex
                break
            }
        }

        blocks.append(contentsOf: parsePlain(String(text[cursor..<text.endIndex])))
        return blocks
    }

    private static func appendThought(_ text: String, to blocks: inout [MarkdownBlock]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { blocks.append(.thought(trimmed)) }
    }

    fileprivate static func parsePlain(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if line.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Table: a pipe row followed by a separator row (|---|---|).
            if line.contains("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                flushParagraph()
                let header = parseRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || !r.contains("|") { break }
                    rows.append(parseRow(r)); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Heading.
            if let level = headingLevel(line) {
                flushParagraph()
                let txt = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: txt))
                i += 1
                continue
            }

            // Bullet list.
            if isBullet(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            // Numbered list.
            if let _ = numberedMarker(line) {
                flushParagraph()
                var items: [(String, String)] = []
                while i < lines.count, let marker = numberedMarker(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    let body = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    items.append((marker, body))
                    i += 1
                }
                blocks.append(.numbered(items))
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

    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func parseRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, line.count > hashes,
              line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    /// Returns the marker (e.g. "1.") if the line is a numbered list item.
    private static func numberedMarker(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(digits) + String(rest.first!)
    }
}
