import SwiftUI

/// Search chats (⌘K, or the conversations menu): finds conversations whose title or messages have
/// every word typed, title matches first, then the newest. Each result shows where it matched.
enum ChatSearch {
    struct Result: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// The matching bit of a message, or nil when the title matched.
        let snippet: String?
        let isActive: Bool
    }

    static func words(_ query: String) -> [String] {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A chat's text, folded once for searching.
    struct Entry {
        let id: UUID
        let title: String
        let foldedTitle: String
        let messages: [(text: String, folded: String)]
    }

    @MainActor
    static func index(_ conversations: [Conversation]) -> [Entry] {
        conversations.filter(\.hasMessages).map { c in
            Entry(id: c.id, title: c.title, foldedTitle: fold(c.title), messages: c.messages.map { ($0.text, fold($0.text)) })
        }
    }

    /// `conversations` newest first.
    @MainActor
    static func results(_ query: String, in conversations: [Conversation], activeID: UUID, limit: Int = 30) -> [Result] {
        results(query, in: index(conversations), activeID: activeID, limit: limit)
    }

    static func results(_ query: String, in entries: [Entry], activeID: UUID, limit: Int = 30) -> [Result] {
        let words = words(query)
        guard !words.isEmpty else {
            return entries.prefix(limit).map { Result(id: $0.id, title: $0.title, snippet: nil, isActive: $0.id == activeID) }
        }
        var titled: [Result] = [], inside: [Result] = []
        for e in entries {
            if words.allSatisfy(e.foldedTitle.contains) {
                titled.append(Result(id: e.id, title: e.title, snippet: nil, isActive: e.id == activeID))
                continue
            }
            guard words.allSatisfy({ word in e.messages.contains { $0.folded.contains(word) } }) else { continue }
            let hit = e.messages.first { $0.folded.contains(words[0]) }
            inside.append(Result(id: e.id, title: e.title, snippet: hit.map { snippet($0.text, around: words[0]) },
                                 isActive: e.id == activeID))
            if titled.count + inside.count >= limit * 2 { break }
        }
        return Array((titled + inside).prefix(limit))
    }

    /// About 90 characters of `text` around the first `word`, on one line.
    static func snippet(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = fold(flat).range(of: word) else { return String(flat.prefix(90)) }
        let at = fold(flat).distance(from: fold(flat).startIndex, to: range.lowerBound)
        let start = max(0, at - 30)
        let chars = Array(flat)
        let end = min(chars.count, start + 90)
        return (start > 0 ? "…" : "") + String(chars[start..<end]).trimmingCharacters(in: .whitespaces) + (end < chars.count ? "…" : "")
    }
}

/// The search over the chat panel: a field, the matching chats, Return opens the selected one, Esc
/// closes. The chats' text is folded once when it opens, not on every keystroke.
struct ChatSearchView: View {
    let close: () -> Void
    /// Newest first; the app's own chats unless given (screenshots).
    var conversations: [Conversation]? = nil
    @State var query = ""
    @State private var selection = 0
    @State private var results: [ChatSearch.Result] = []
    @State private var index: [ChatSearch.Entry] = []
    @State private var notice: String?
    @FocusState private var focused: Bool
    private var chat: ChatController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { open(results.indices.contains(selection) ? results[selection] : nil) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onChange(of: query) { _, _ in refresh() }
                Button("Done", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if results.isEmpty {
                Text(query.isEmpty ? "No chats yet." : "No chat has “\(query)”.")
                    .foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, selected: index == selection)
                                    .id(index)
                                    // Only a moving mouse picks a row: one resting over the list while
                                    // the results change under it doesn't steal Return.
                                    .onContinuousHover { phase in if case .active = phase { selection = index } }
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: selection) { _, new in proxy.scrollTo(new) }
                }
            }
        }
        .onAppear {
            index = ChatSearch.index(conversations ?? chat.sessions.reversed())
            refresh()
            focused = true
        }
    }

    private func row(_ result: ChatSearch.Result, selected: Bool) -> some View {
        Button { open(result) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title).lineLimit(1)
                    if result.isActive { Text("open").font(.caption2).foregroundStyle(.secondary) }
                }
                if let snippet = result.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        results = ChatSearch.results(query, in: index, activeID: chat.active.id)
        selection = 0
    }

    private func open(_ result: ChatSearch.Result?) {
        guard let result else { return }
        if !result.isActive {
            guard !chat.active.isStreaming else { notice = "Stop the reply first (⌘. or Esc), then open it."; return }
            chat.switchTo(result.id)
        }
        close()
    }
}
