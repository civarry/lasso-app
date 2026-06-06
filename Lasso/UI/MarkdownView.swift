import SwiftUI

/// Lightweight, dependency-free Markdown block renderer for AI output. Handles the constructs local
/// models commonly emit: tables (→ SwiftUI Grid), headings, bullet/numbered lists, fenced code, and
/// paragraphs (inline **bold**/*italic*/`code`/links via AttributedString). Anything unrecognized
/// falls back to plain paragraph text, and partial Markdown mid-stream renders best-effort.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 15

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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: fontSize - 1, design: .monospaced))
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
        return ScrollView(.horizontal, showsIndicators: false) {
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

// MARK: - Parser

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered([(String, String)])
    case code(String)
    case table(header: [String], rows: [[String]])
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
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
