import SwiftUI

/// Settings is laid out like macOS System Settings: a sidebar of panes with colored icon tiles; a pane is
/// either a hub (a header, then grouped rows that each open a page) or shows its controls directly.

// MARK: - Panes and pages

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, toolbar, models, agent, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .toolbar: "Toolbar"
        case .models: "Models"
        case .agent: "Agent"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .toolbar: "rectangle.3.group.fill"
        case .models: "cpu.fill"
        case .agent: "terminal.fill"
        case .privacy: "hand.raised.fill"
        }
    }

    /// Flat tile colors on the macOS palette: General gray like the system's, Privacy blue like
    /// Privacy & Security, Agent warm because it's the pane that runs commands.
    var color: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .toolbar: Color(white: 0.32)
        case .models: Color(nsColor: .systemIndigo)
        case .agent: Color(nsColor: .systemOrange)
        case .privacy: Color(nsColor: .systemBlue)
        }
    }

    /// One line under a hub's title.
    var summary: String {
        switch self {
        case .general: "Shortcuts, translation, updates and startup."
        case .toolbar: "Choose which actions appear and in what order."
        case .models: "The AI models Lasso uses for text, images and memory."
        case .agent: "Lets chat search the web, read files and run commands."
        case .privacy: "Control what leaves your Mac."
        }
    }

    /// Paused by local-only mode (a lock in the sidebar).
    var pausedByLocalOnly: Bool { self == .agent }
}

/// A page opened from a row (pushed onto the pane's navigation stack).
enum SettingsRoute: String, Hashable, CaseIterable {
    case about, softwareUpdate, shortcuts, translation
    case languageModel, imageModel, embeddingModel, ollama
    case ownHermes, searchKeys

    var title: String {
        switch self {
        case .about: "About"
        case .softwareUpdate: "Software Update"
        case .shortcuts: "Keyboard Shortcuts"
        case .translation: "Translation"
        case .languageModel: "Language Model"
        case .imageModel: "Image Model"
        case .embeddingModel: "Embedding Model"
        case .ollama: "Ollama"
        case .ownHermes: "Use My Own Hermes"
        case .searchKeys: "Search API Keys"
        }
    }

    var symbol: String {
        switch self {
        case .about: "info.circle.fill"
        case .softwareUpdate: "arrow.down.circle.fill"
        case .shortcuts: "keyboard.fill"
        case .translation: "character.bubble.fill"
        case .languageModel: "text.bubble.fill"
        case .imageModel: "photo.fill"
        case .embeddingModel: "brain.fill"
        case .ollama: "server.rack"
        case .ownHermes: "network"
        case .searchKeys: "key.fill"
        }
    }

    var color: Color {
        switch self {
        case .about: Color(nsColor: .systemGray)
        case .softwareUpdate: Color(nsColor: .systemGray)
        case .shortcuts: Color(nsColor: .systemGray)
        case .translation: Color(nsColor: .systemBlue)
        case .languageModel: Color(nsColor: .systemIndigo)
        case .imageModel: Color(nsColor: .systemTeal)
        case .embeddingModel: Color(nsColor: .systemPurple)
        case .ollama: Color(white: 0.32)
        case .ownHermes: Color(nsColor: .systemOrange)
        case .searchKeys: Color(nsColor: .systemGray)
        }
    }

    /// The pane the page lives in (search uses it to open the right place).
    var pane: SettingsPane {
        switch self {
        case .about, .softwareUpdate, .shortcuts, .translation: .general
        case .languageModel, .imageModel, .embeddingModel, .ollama: .models
        case .ownHermes: .agent
        case .searchKeys: .privacy
        }
    }
}

// MARK: - Search

/// What the sidebar's search field finds: a setting's label (and words people might type instead), and
/// where it lives. Hand-written, so `SettingsSearchTests` checks every entry still leads somewhere.
struct SettingsSearchEntry: Identifiable, Hashable {
    let label: String
    let pane: SettingsPane
    let route: SettingsRoute?
    var keywords: [String] = []
    var id: String { "\(pane.rawValue)/\(route?.rawValue ?? "-")/\(label)" }

    /// "Pane › Page" under the result.
    var location: String { [pane.title, route?.title].compactMap { $0 }.joined(separator: " › ") }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        return ([label, location] + keywords).contains { $0.lowercased().contains(q) }
    }

    static let all: [SettingsSearchEntry] = [
        .init(label: "Capture shortcut", pane: .general, route: .shortcuts, keywords: ["hotkey", "keyboard"]),
        .init(label: "Chat shortcut", pane: .general, route: .shortcuts, keywords: ["hotkey", "keyboard"]),
        .init(label: "Proofread highlighted text", pane: .general, route: .shortcuts, keywords: ["hotkey", "grammar"]),
        .init(label: "Full screen", pane: .general, route: .shortcuts, keywords: ["hotkey", "identify", "lens"]),
        .init(label: "Toolbar action shortcuts", pane: .general, route: .shortcuts, keywords: ["hotkey", "keyboard"]),
        .init(label: "Pre-translate selections", pane: .general, route: .translation, keywords: ["translate"]),
        .init(label: "Better translation", pane: .general, route: .translation, keywords: ["translate"]),
        .init(label: "Open at login", pane: .general, route: nil, keywords: ["launch", "startup"]),
        .init(label: "Automatically check for updates", pane: .general, route: .softwareUpdate, keywords: ["update", "version"]),
        .init(label: "Install updates automatically", pane: .general, route: .softwareUpdate, keywords: ["update"]),
        .init(label: "Version", pane: .general, route: .about, keywords: ["about"]),
        .init(label: "Toolbar style", pane: .toolbar, route: nil, keywords: ["compact", "comfortable", "appearance"]),
        .init(label: "Hide unavailable actions", pane: .toolbar, route: nil),
        .init(label: "Color-code actions", pane: .toolbar, route: nil, keywords: ["colors"]),
        .init(label: "Toolbar actions order", pane: .toolbar, route: nil, keywords: ["reorder", "show", "hide"]),
        .init(label: "Language model", pane: .models, route: .languageModel, keywords: ["llm", "mlx", "openai", "anthropic", "api key", "connection"]),
        .init(label: "Image model", pane: .models, route: .imageModel, keywords: ["vision", "multimodal"]),
        .init(label: "Embedding model", pane: .models, route: .embeddingModel, keywords: ["memory"]),
        .init(label: "Free-model fallback", pane: .models, route: .languageModel, keywords: ["free", "rate limit"]),
        .init(label: "Ollama server", pane: .models, route: .ollama, keywords: ["local"]),
        .init(label: "Agent status", pane: .agent, route: nil, keywords: ["hermes", "set up"]),
        .init(label: "Ask before risky commands", pane: .agent, route: nil, keywords: ["approval", "hermes"]),
        .init(label: "Use my own Hermes", pane: .agent, route: .ownHermes, keywords: ["gateway", "api key", "address"]),
        .init(label: "Local-only mode", pane: .privacy, route: nil, keywords: ["offline", "network", "privacy"]),
        .init(label: "Web search", pane: .privacy, route: nil, keywords: ["internet", "grounding", "connector"]),
        .init(label: "Search with Lens", pane: .privacy, route: nil, keywords: ["google", "reverse image"]),
        .init(label: "Search API keys", pane: .privacy, route: .searchKeys, keywords: ["tavily", "serpapi", "api key"]),
        .init(label: "Clear chat history", pane: .privacy, route: nil, keywords: ["delete", "conversations"]),
    ]

    static func results(for query: String) -> [SettingsSearchEntry] { all.filter { $0.matches(query) } }
}

// MARK: - Building blocks

/// A rounded-square icon with a white glyph, like System Settings'.
struct SettingsTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white))
    }
}

/// The card at the top of a hub: big tile, title, one line.
struct SettingsHubHeader: View {
    let pane: SettingsPane

    var body: some View {
        VStack(spacing: 8) {
            SettingsTile(symbol: pane.symbol, color: pane.color, size: 56)
            Text(pane.title).font(.title2.bold())
            Text(pane.summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(SettingsPalette.cardFill, in: RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
            .strokeBorder(SettingsPalette.cardBorder, lineWidth: 1))
    }
}

/// A row that opens a page: tile, title, the current value, chevron.
struct SettingsLinkRow: View {
    let route: SettingsRoute
    var value: String?
    var locked = false

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SettingsTile(symbol: route.symbol, color: route.color)
                    Text(route.title).font(SettingsFont.label)
                    Spacer(minLength: 8)
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let value, !value.isEmpty {
                        Text(value).font(SettingsFont.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                Divider().padding(.leading, SettingsMetrics.rowPaddingH + 32)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A hub or direct pane's scrolling page in Lasso's card style.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(SettingsMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsPalette.pageFill)
    }
}

// MARK: - Window

/// The Settings window (a regular `Window` scene; see `LassoApp`).
enum SettingsWindow {
    static let id = "settings"

    /// Opens it (or brings it forward) in front of other apps: Lasso is a menu bar app with no Dock icon,
    /// so it has to activate itself for its window to come to the front.
    @MainActor static func open(with openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
    }
}
