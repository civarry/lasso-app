import SwiftUI

/// Renders parsed Markdown blocks (see `MarkdownDocument.swift`) as SwiftUI.
///
/// The visual rules are deliberately restrained: one type scale, one radius, one surface tint, and
/// no decoration that isn't carrying information. Model output is already noisy — the renderer's job
/// is to make its structure legible, not to add more.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 15
    /// Whether text in this render is drag-selectable. Off in the Chat panel, where selectable text
    /// intercepts clicks meant for nearby controls (the Activity disclosure) — chat uses a Copy button instead.
    var selectable: Bool = true
    /// True while tokens are still arriving, which turns on the parser's streaming-stability pass.
    var streaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text, streaming: streaming).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, fontSize: fontSize, selectable: selectable)
            }
        }
        // Propagate selection to every text block (paragraphs, lists, tables, code) — not just code.
        .textSelectable(selectable)
    }
}

// MARK: - Blocks

/// One block, as its own view. Blockquotes contain blocks, so the recursion has to pass through a
/// nominal type — a `@ViewBuilder` method that calls itself would make the opaque return type
/// infinite and fails to compile.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat
    let selectable: Bool

    var body: some View {
        switch block {
        case .thought(let s):
            ThoughtDisclosure(text: s, fontSize: fontSize)

        case .paragraph(let s):
            inline(s).font(.system(size: fontSize))

        case .heading(let level, let s):
            inline(s).font(.system(size: fontSize + CGFloat(max(0, 4 - level)) * 2 + 2, weight: .bold))
                .padding(.top, 2)

        case .list(let items):
            ListView(items: items, fontSize: fontSize)

        case .code(let language, let content, let closed):
            CodeBlockView(language: language, content: content, complete: closed,
                          fontSize: fontSize, selectable: selectable)

        case .table(let table):
            if table.isDegenerate {
                degenerateTable(table)
            } else {
                tableView(table)
            }

        case .quote(let blocks):
            QuoteView(blocks: blocks, fontSize: fontSize, selectable: selectable)

        case .math(let expression):
            // Not typeset — converted to Unicode by `MathText`. It gets its own surface, a step up in
            // size, and room to breathe: in an answer about a formula the equation is the thing the
            // user came for, and at body size in a 420pt panel it read as the least important line.
            //
            // Deliberately NOT inside `HScroll`. Converted math is space-separated text, so it wraps
            // at sensible points, and wrapping beats scrolling here — a formula you have to drag
            // sideways to finish reading is worse than one on two lines. (It also fixes the centring:
            // `maxWidth: .infinity` inside a horizontal ScrollView resolves against the content, not
            // the viewport, so the old version silently rendered flush left.)
            Text(expression)
                .font(.system(size: fontSize + 4))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                .padding(.vertical, 2)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func inline(_ s: String) -> Text {
        Text(AttributedString.fromMarkdown(s))
    }

    // MARK: Tables

    private func tableView(_ table: MarkdownTable) -> some View {
        let columns = table.columnCount
        return HScroll {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < table.header.count ? table.header[c] : "",
                             weight: .semibold, alignment: table.alignment(c))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < row.count ? row[c] : "",
                                 weight: .regular, alignment: table.alignment(c))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
    }

    /// A one-row or one-column "table" holds nothing to compare, so the grid is pure furniture. Show
    /// the same content as label/value lines — it reads faster and stops the layout from lurching
    /// between prose and a boxed grid as the model's formatting habits change from turn to turn.
    private func degenerateTable(_ table: MarkdownTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                ForEach(Array(row.enumerated()), id: \.offset) { c, value in
                    if !value.isEmpty {
                        let label = c < table.header.count ? table.header[c] : ""
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if !label.isEmpty {
                                inline(label).font(.system(size: fontSize, weight: .semibold))
                            }
                            inline(value).font(.system(size: fontSize))
                        }
                    }
                }
            }
        }
    }

    /// Column alignment comes from the separator row (`|---:|:--:|`), which is the one piece of table
    /// styling models get right often enough to honour — numbers right-aligned actually aid scanning.
    private func cell(_ s: String, weight: Font.Weight, alignment: MarkdownTable.Alignment) -> some View {
        let (frame, text): (Alignment, TextAlignment) = switch alignment {
        case .leading: (.leading, .leading)
        case .center: (.center, .center)
        case .trailing: (.trailing, .trailing)
        }
        return Text(AttributedString.fromMarkdown(s))
            .font(.system(size: fontSize - 1, weight: weight))
            .multilineTextAlignment(text)
            .frame(maxWidth: .infinity, alignment: frame)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct QuoteView: View {
    let blocks: [MarkdownBlock]
    let fontSize: CGFloat
    let selectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                MarkdownBlockView(block: inner, fontSize: fontSize, selectable: selectable)
            }
        }
        .padding(.leading, 10)
        .foregroundStyle(.secondary)
        .overlay(alignment: .leading) {
            Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2)
        }
    }
}

// MARK: - Lists

/// Bullets, numbers and task items in one view so a list that mixes them (a checklist nested under a
/// numbered step) keeps consistent indentation. Depth comes from the parser, which normalises the
/// model's indentation before it gets here.
private struct ListView: View {
    let items: [MarkdownListItem]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item)
                    Text(AttributedString.fromMarkdown(item.text))
                        .font(.system(size: fontSize))
                        .strikethrough(item.checked == true, color: .secondary)
                        .foregroundStyle(item.checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else if let marker = item.marker {
            Text(marker)
                .font(.system(size: fontSize, weight: .medium).monospacedDigit())
        } else {
            // Depth is legible from the glyph as well as the indent, which matters when a nested
            // list wraps onto several lines.
            Text(["•", "◦", "▪"][min(item.depth, 2)])
                .font(.system(size: fontSize))
                .foregroundStyle(item.depth == 0 ? Color.primary : Color.secondary)
        }
    }
}

private extension View {
    /// `.textSelection(.enabled/.disabled)` can't go in a ternary (different concrete types), so
    /// branch via @ViewBuilder.
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

// MARK: - Code block (language header + per-block copy)

/// A fenced code block rendered like established chat apps: a header row with the language label and a
/// Copy button that copies ONLY this block's code, above the horizontally-scrollable monospaced body.
private struct CodeBlockView: View {
    let language: String?
    let content: String
    /// False while the closing fence hasn't arrived. The block still renders as code — the point of
    /// the flag is to withhold the Copy button, since copying half a snippet is worse than waiting.
    let complete: Bool
    let fontSize: CGFloat
    let selectable: Bool
    @State private var copied = false
    /// After Run, the block shows its console; Code switches back. Unset: the console when there's a run.
    @State private var showRun: Bool?
    private var showingRun: Bool { showRun ?? (run != nil) }
    @Environment(\.codeBlockContext) private var context
    private var runner: CodeRunner { .shared }

    private var key: String? { context.map { CodeRunner.key($0.message, content) } }
    private var run: CodeRunner.Run? { key.flatMap { runner.run($0) } }
    private var commands: [(entry: PackageRegistry.Entry, command: PackageCommand)] {
        context != nil && complete ? runner.commands(for: language) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: fontSize - 4))
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.system(size: fontSize - 3, weight: .medium))
                Spacer()
                if complete {
                    Button {
                        Pasteboard.copy(showingRun ? consoleText : content)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: fontSize - 3))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .help(showingRun ? "Copy the output" : "Copy this code block")
                }
                if showingRun, run != nil {
                    Button { showRun = false } label: {
                        Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: fontSize - 3)).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .help("Show the code")
                } else {
                    ForEach(commands, id: \.command.id) { item in
                        Button {
                            guard let key, let context else { return }
                            runner.start(item.entry, item.command, code: content, language: language ?? "",
                                         reply: context.reply, key: key)
                            showRun = true
                        } label: {
                            Label(item.command.title, systemImage: item.command.symbol ?? "play")
                                .font(.system(size: fontSize - 3, weight: .medium)).labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(run?.running == true)
                        .help("\(item.command.title) with \(item.entry.package.name)")
                    }
                    if !showingRun, run != nil {
                        Button { showRun = true } label: {
                            Label("Output", systemImage: "terminal")
                                .font(.system(size: fontSize - 3)).labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .help("Show the last run")
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.05))

            if showingRun, let run, let key {
                CodeConsoleView(run: run, fontSize: fontSize, perform: { runner.perform($0, key: key) })
            } else {
                HScroll {
                    Text(content)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .textSelectable(selectable)
                        .padding(8)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var consoleText: String {
        guard let run else { return "" }
        return run.console?.text ?? run.error ?? run.lines.joined(separator: "\n")
    }
}

/// A run in its code block: the steps (dim), the output, the picture, how long it took, and the
/// buttons the script offered.
private struct CodeConsoleView: View {
    let run: CodeRunner.Run
    let fontSize: CGFloat
    let perform: (PackageScript.Console.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(run.lines.enumerated()), id: \.offset) { _, line in
                Text(line).foregroundStyle(.secondary)
            }
            if run.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Running…").foregroundStyle(.secondary)
                }
            }
            if let console = run.console {
                if !console.text.isEmpty {
                    Text(console.text)
                        .foregroundStyle(console.failed ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = console.image, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 520, maxHeight: 400, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture {
                            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                ImageViewer.shared.show(cg, title: url.lastPathComponent, file: url)
                            }
                        }
                        .help("Click to open it larger")
                }
            }
            if let error = run.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let elapsed = run.elapsed {
                Text(run.error != nil || run.console?.failed == true
                     ? "Run failed after \(Self.duration(elapsed))" : "Run completed in \(Self.duration(elapsed))")
                    .foregroundStyle(.secondary)
            }
            if let actions = run.console?.actions, !actions.isEmpty, !run.running {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help(action.chat != nil ? "Asks the chat model" : action.title)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.system(size: fontSize - 2, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
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
