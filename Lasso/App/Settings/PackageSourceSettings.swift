import AppKit
import KeyboardShortcuts
import SwiftUI

/// A source's own settings (docs/LOCAL-SOURCES.md): Use it (automatically or only when @-mentioned),
/// What's in it (what Lasso ranks against), and which cloud companies may receive its passages.
struct SourceSettingsCard: View {
    let source: PackageSource
    @State private var about = ""
    @State private var use: SourcePreferences.Use = .automatically
    @State private var allowed: [String] = []
    @State private var save: Task<Void, Never>?

    var body: some View {
        SettingsCard(title: "In chat", footnote: about.isEmpty
                        ? "Add a line to What's in it first: Lasso reads it to decide when to look."
                        : "Lasso reads What's in it to decide when to look. Use the words you'd ask with.") {
            SettingsRow("Use it") {
                Picker("", selection: Binding(get: { use }, set: { use = $0; SourcePreferences.setUse($0, source.id) })) {
                    Text("Automatically").tag(SourcePreferences.Use.automatically)
                    Text("Only when I @ it").tag(SourcePreferences.Use.onlyWhenMentioned)
                }
                .labelsHidden().settingsCappedMenu()
                .disabled(about.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What's in it").font(SettingsFont.label)
                TextField("", text: $about, prompt: Text("Meeting notes, project plans, pricing decisions"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: about) { _, text in
                        if text.count > SourcePreferences.maxAbout { about = String(text.prefix(SourcePreferences.maxAbout)) }
                        save?.cancel()
                        save = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            if !Task.isCancelled { SourcePreferences.setAbout(about, source.id) }
                        }
                    }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, SettingsMetrics.rowPaddingV)
            Divider()
            if !allowed.isEmpty {
                SettingsRow("Allowed to send to", caption: allowed.map(Self.companyName).joined(separator: ", ")) {
                    Button("Reset") { SourcePreferences.resetAllowed(source.id); allowed = [] }.buttonStyle(.bordered)
                }
            }
        }
        .onAppear {
            about = SourcePreferences.about(source.id)
            use = SourcePreferences.use(source.id)
            allowed = SourcePreferences.allowed(source.id)
        }
        .onDisappear { save?.cancel(); SourcePreferences.setAbout(about, source.id) }
        .onReceive(NotificationCenter.default.publisher(for: SourcePreferences.aboutChanged)) { note in
            if note.object as? String == source.id { about = SourcePreferences.about(source.id) }
        }
    }

    static func companyName(_ key: String) -> String {
        ["anthropic.com": "Anthropic", "openai.com": "OpenAI", "groq.com": "Groq", "openrouter.ai": "OpenRouter",
         "googleapis.com": "Google", "mistral.ai": "Mistral"][key] ?? key
    }
}

/// The Test card for a source: the user's own words, what it found, and whether Lasso would look there
/// for a message like that (with the missing words to add to What's in it).
struct SourceTestCard: View {
    let source: PackageSource
    let blocked: String?
    @State private var query = ""
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle, running
        case found(count: Int, ms: Int, files: [String], checked: Int?)
        case failed(String)
    }

    var body: some View {
        SettingsCard(title: "Test") {
            HStack(spacing: SettingsMetrics.columnGap) {
                TextField("", text: $query, prompt: Text(source.isOnThisMac ? "A word from your notes" : "Something to search for"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("Test", action: run).buttonStyle(.bordered)
                    .disabled(blocked != nil || query.trimmingCharacters(in: .whitespaces).isEmpty || phase == .running)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, SettingsMetrics.rowPaddingV)
            Divider()
            if let blocked {
                line(blocked, warn: true)
            } else {
                switch phase {
                case .idle: line(source.isOnThisMac ? "Type words you'd ask about, then Test." : "Type a search, then Test.", warn: false)
                case .running: HStack { ProgressView().controlSize(.small); Text("Searching…").font(SettingsFont.sub) }
                        .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
                case .failed(let why): line(why, warn: true)
                case .found(let count, let ms, let files, let checked):
                    if count == 0 {
                        line("No file mentions “\(query)”." + (checked.map { " Checked \($0) Markdown file\($0 == 1 ? "" : "s")." } ?? ""), warn: false)
                    } else {
                        line("\(count) match\(count == 1 ? "" : "es") in \(ms) ms", warn: false)
                        ForEach(files, id: \.self) { line($0, warn: false, symbol: "doc.text") }
                    }
                    if source.isOnThisMac { decision }
                }
            }
        }
    }

    /// Whether Lasso would look here for a message with these words, and which ones to add if not.
    @ViewBuilder private var decision: some View {
        let about = SourcePreferences.about(source.id)
        if SourcePreferences.use(source.id) == .onlyWhenMentioned {
            line("Lasso looks here only when you type @\(source.name).", warn: false, symbol: "at")
        } else if !SourcePicker.automatic(query, from: [source]).isEmpty {
            line("Lasso would look here for this message.", warn: false, symbol: "checkmark.circle")
        } else {
            let have = Set(SourceWords.content(about))
            let missing = SourceWords.whole(query).filter { !have.contains(SourceWords.stem($0)) }
            VStack(alignment: .leading, spacing: 6) {
                Label("Lasso wouldn't look here for this. Add these words to What's in it?", systemImage: "exclamationmark.circle")
                    .font(SettingsFont.sub).foregroundStyle(.orange)
                HStack(spacing: 6) {
                    ForEach(missing.prefix(5), id: \.self) { word in
                        Button("+ \(word)") { add(word) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
        }
    }

    private func add(_ word: String) {
        let about = SourcePreferences.about(source.id)
        SourcePreferences.setAbout(about.isEmpty ? word : "\(about), \(word)", source.id)
        NotificationCenter.default.post(name: SourcePreferences.aboutChanged, object: source.id)
        let q = query; query = ""; query = q   // redraw the decision
    }

    private func line(_ text: String, warn: Bool, symbol: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16) }
                Text(text).font(SettingsFont.sub).foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 8)
            Divider()
        }
    }

    private func run() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, blocked == nil else { return }
        phase = .running
        let started = Date()
        let source = source
        Task {
            do {
                let hits = try await SourceSearch.run(source, words)
                let checked = Self.markdownCount(source)
                phase = .found(count: hits.count, ms: Int(Date().timeIntervalSince(started) * 1000),
                               files: hits.prefix(3).map { $0.url?.lastPathComponent ?? $0.title }, checked: checked)
            } catch {
                phase = .failed(PackageHTTP.redact(error.localizedDescription, secrets: source.entry.secrets))
            }
        }
    }

    /// How many Markdown and text files its folder holds (shows the search really looked).
    static func markdownCount(_ source: PackageSource) -> Int? {
        guard let setting = source.entry.package.settings.first(where: { $0.kind == .folder }),
              let path = source.entry.values["settings.\(setting.id)"], !path.isEmpty,
              let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var n = 0
        for case let url as URL in walker where ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            n += 1
            if n >= 10_000 { break }
        }
        return n
    }
}

/// "How to use it": one line per way a package shows up in Lasso, from its manifest and what's set up
/// now (docs/LOCAL-SOURCES.md). Never an invented example, never a key that isn't set.
enum PackageHowTo {
    struct Line: Hashable { var symbol: String; var text: AttributedString }

    @MainActor
    static func lines(_ package: LassoPackage, store: PackageStore = .shared) -> [Line] {
        var out: [Line] = []
        func add(_ symbol: String, _ markdown: String) {
            out.append(Line(symbol: symbol, text: (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)))
        }
        let missing = store.missingSettings(package)
        if let folder = missing.first(where: { $0.kind == .folder }) {
            add("folder", "Choose its \(folder.label.lowercased()) below first.")
        } else if missing.contains(where: { $0.kind == .secret }) {
            add("key", "Add your API key below first.")
        }
        let values = store.settingValues(for: package).values
        let entry = PackageRegistry.Entry(package: package, values: values, secrets: [], ready: true)
        for command in package.commands {
            // The author's own line says it best when there is one.
            if let howTo = command.howTo {
                let symbol = command.surfaces.contains(.toolbar) ? "cursorarrow.click" : "info.circle"
                add(symbol, howTo)
                continue
            }
            for surface in command.surfaces {
                switch surface {
                case .search:
                    if PackageSource.isOnThisMac(entry, command) {
                        add("at", "In chat, type **@\(package.name)** and your question. Or just ask: Lasso looks here by itself when a message fits What's in it.")
                    } else {
                        add("globe", "Turn on web search (the globe) and ask, or type **@\(package.name)** to search only it.")
                    }
                case .slash: add("slash.circle", "Type **/\(command.id)** in chat.")
                case .toolbar:
                    let when = ActionBarCatalog.whenPhrase(command.when).replacingOccurrences(of: " · ", with: "")
                    add("cursorarrow.click", command.input.contains(.table)
                        ? "Lasso a table on screen, then click **\(command.title)** in the toolbar."
                        : when.isEmpty ? "Lasso something, then click **\(command.title)** in the toolbar."
                        : "Lasso something, then click **\(command.title)** in the toolbar. It shows \(when).")
                case .send: add("square.and.arrow.up", "After a capture or a chat reply, choose **Send to › \(command.title)**.")
                case .hotkey:
                    if let key = KeyboardShortcuts.getShortcut(for: PackageHotkeys.name(package.id, command.id)) {
                        add("keyboard", "Highlight text in any app and press **\(key.description)**.")
                    } else {
                        add("keyboard", "Set a shortcut for **\(command.title)** in Settings › Keyboard Shortcuts, then use it on highlighted text.")
                    }
                case .tool: add("bubble.left", "Just ask in chat; the model uses **\(command.title)** when it helps.")
                }
            }
        }
        if !package.patches.isEmpty { add("slider.horizontal.3", "Changes Lasso itself. Nothing to do.") }
        var seen = Set<String>()
        return Array(out.filter { seen.insert(String($0.text.characters)).inserted }.prefix(4))
    }
}

struct PackageHowToCard: View {
    let package: LassoPackage
    var body: some View {
        let lines = PackageHowTo.lines(package)
        if !lines.isEmpty {
            SettingsCard(title: "How to use it") {
                ForEach(lines, id: \.self) { line in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: line.symbol).foregroundStyle(.secondary).frame(width: 16)
                            Text(line.text).font(SettingsFont.label).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SettingsMetrics.rowPaddingH).padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
    }
}

extension SourcePreferences {
    /// Posted with the source's id when What's in it changes outside its field (Test card chips).
    static let aboutChanged = Notification.Name("lasso.sources.aboutChanged")
}
