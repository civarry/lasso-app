import SwiftUI
import KeyboardShortcuts

/// Which model a capability card has chosen out of the shared registry. `.model` carries the exact
/// key id (not just the name) so same-named models under two keys route to the right backend;
/// `.manual` is a hand-typed name in the "Manually added" group; `.sameAsLanguage` (image/embedding
/// only) tracks whatever the Language card currently points at.
enum ModelSelection: Equatable, Sendable {
    case none
    case sameAsLanguage
    case model(keyID: String, name: String)
    case manual(name: String)

    /// The model name this selection resolves to on its own (nil for `.none`/`.sameAsLanguage`, which
    /// must be resolved against the registry / the language selection by the caller).
    var directName: String? {
        switch self {
        case .model(_, let name), .manual(let name): return name
        case .none, .sameAsLanguage: return nil
        }
    }
}

struct SettingsView: View {
    @Bindable var intelligence: IntelligenceCoordinator

    /// All editable settings are staged here and committed together via "Save & Apply" — one place
    /// to save, instead of a Save button per field.
    private struct Draft: Equatable {
        var provider: ProviderKind = .onDevice
        var ollamaModel = ""
        var ollamaBaseURL = ""          // custom Ollama server URL; "" = Auto (localhost:11434)
        var ollamaAutoStart = false     // start Ollama when Lasso launches (only if installed)
        var mlxModel = MLXProvider.defaultModelID
        var visionModel = ""
        var visionMLXModel = MLXVisionProvider.defaultModelID
        // OpenAI-compatible is now an omni-router: a single app-level registry of keys (each an
        // endpoint with its own URL / key / discovered models) shared by all three cards. Each card
        // picks a model out of the merged, capability-filtered list; `*Selection` records which key +
        // model that card chose (or "same as language" for image/embedding). The key *values* live in
        // the Keychain, not in the Draft.
        var registry = KeysRegistry()
        var langSelection = ModelSelection.none
        var visionSelection = ModelSelection.none
        var embeddingSelection = ModelSelection.none
        var langContext: Int = 0          // manual context-window override for the selected language model (0 = Auto)
        var autoFallback = false          // retry a failed cloud request on a free model from the connections
        var fallbackRaceAfter = 15        // seconds before a free model races a slow one; 0 = never
        var anthropicBaseURL = "https://api.anthropic.com"
        var anthropicModel = "claude-3-5-haiku-latest"
        var anthropicKey = ""
        // Independent image (vision) provider.
        var visionEngine: VisionEngine = .matchText
        var visionAnthropicBaseURL = "https://api.anthropic.com"
        var visionAnthropicModel = "claude-3-5-sonnet-latest"
        var visionAnthropicKey = ""
        // Embedding model (Chat semantic memory).
        var embeddingProvider: EmbeddingProviderKind = .automatic
        var embeddingOllamaModel = ""       // "" = Auto (best installed embed model)
        var embeddingMLXModel = MLXEmbeddings.defaultModelID

        // Active-service convenience, computed from the registry + current selection (consumed by
        // privacyLine, ConnectionTest, hints). Selection is resolved via the registry, not stored URLs.
        // Connector enable + key state, keyed by Connector.id — the catalog is the single source of
        // truth, so adding a connector needs no new Draft fields.
        var connectorEnabled: [String: Bool] = [:]
        var connectorKeys: [String: String] = [:]
        var localOnly = false
        var lensSearch = false
        var pretranslate = true
        var launchAtLogin = false
        // Appearance — staged like everything else so changing them flips "Unsaved changes" and
        // applies on Save & Apply (not instantly), for a consistent Settings experience.
        var actionBarStyle = ActionBarStyle.compact.rawValue
        var hideUnavailable = false
        var colorfulActions = false
    }

    private enum Tab: Hashable { case general, intelligence, connectors, about }

    @State private var tab: Tab = .general
    @State private var showClearHistoryConfirm = false
    @State private var embeddingStatus: (ok: Bool, text: String)?
    @State private var embeddingStatusTask: Task<Void, Never>?
    @State private var draft = Draft()
    @State private var saved = Draft()
    @State private var availableModels: [String] = []
    @State private var modelsLoaded = false
    @State private var testState: ConnectionTest.Outcome = .idle

    // Fetched cloud model catalogs (Anthropic), like the Ollama model list.
    @State private var anthropicModels: [String] = []
    @State private var visionAnthropicModels: [String] = []
    @State private var loadingModels = false
    @State private var modelLoadNote: String?

    // Omni-router registry UI state. Draft key *values* are held here (loaded from Keychain in
    // load(), committed in apply()) keyed by RegisteredKey.id — the Draft itself never carries
    // secrets. `registryTest` is the per-card model-aware Test result; `discovering` guards refetches.
    @State private var registryKeyValues: [String: String] = [:]
    @State private var registrySearch: [ModelCapability: String] = [:]
    @State private var modelPickerOpenFor: ModelCapability?   // which card's model popover is open
    @State private var showConnections = false           // the connection manager sheet
    @State private var connectionsTest: ConnectionTest.Outcome = .idle
    @State private var connectionsTestNote: String?
    @State private var discoveringKeyIDs: Set<String> = []
    @State private var savedRegistryKeyValues: [String: String] = [:]   // baseline for "unsaved changes" diff
    @State private var showMigrationNotice = false
    @State private var ollamaStatus: OllamaEndpoint.Status?
    @State private var mlxDownload: MLXDownloadState = .idle
    @State private var mlxInstalled: [MLXCache.Entry] = []
    @State private var mlxRemoteSize: Int64?
    @State private var mlxSizeLoading = false
    @State private var mlxSizeTask: Task<Void, Never>?
    @State private var mlxProgress: Double = 0          // 0–1, when the total size is known
    @State private var mlxDownloadedBytes: Int64 = 0
    @State private var mlxDownloadTask: Task<Void, Never>?
    @State private var mlxPollTask: Task<Void, Never>?
    @State private var mlxRemoveConfirm = false
    @State private var mlxLastProgressAt = Date()
    @State private var mlxStalled = false

    enum MLXDownloadState: Equatable { case idle, downloading, ready, failed(String) }

    // Appearance prefs are staged in `draft` (not bound to @AppStorage here) so they apply on
    // Save & Apply like the rest. The keys they persist to:
    private static let actionBarStyleKey = "ui.actionBarStyle"
    private static let hideUnavailableKey = "ui.actionBarHideUnavailable"
    private static let colorfulKey = "ui.actionBarColorful"

    /// Fixed width + gap for the direct-shortcut recorders so the Selection / Full screen columns line
    /// up with their headers (the recorders are flexible-width otherwise).
    private let directRecorderWidth: CGFloat = 128
    private let directRecorderGap: CGFloat = 10

    private func directHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: directRecorderWidth, alignment: .center)
    }

    private var isDirty: Bool { draft != saved || registryKeyValues != savedRegistryKeyValues }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
                intelligenceTab.tabItem { Label("Intelligence", systemImage: "sparkles") }.tag(Tab.intelligence)
                connectorsTab.tabItem { Label("Connectors", systemImage: "puzzlepiece.extension") }.tag(Tab.connectors)
                about.tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
            }
            // The save bar is only meaningful for the editable tabs — About has nothing to apply.
            if tab != .about { actionBar }
        }
        .frame(width: 560, height: 620)
        .task { await load() }
    }

    // MARK: - Save & Apply bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.localOnly ? "lock.shield.fill" : "lock.shield")
                .foregroundStyle(draft.localOnly ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            Text(isDirty ? "Unsaved changes" : "All changes saved")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isDirty {
                Button("Revert") { draft = saved; registryKeyValues = savedRegistryKeyValues }
                    .buttonStyle(.bordered)
            }
            Button("Save & Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isDirty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture", name: .capture)
                KeyboardShortcuts.Recorder("Chat", name: .chat)
                // Single-mode direct action (runs on a selection) — sits with the other single-key
                // rows rather than the two-column grid below.
                KeyboardShortcuts.Recorder("Proofread", name: .grammarSelection)

                LabeledContent("") {
                    HStack(spacing: directRecorderGap) {
                        directHeader("Selection")
                        directHeader("Full screen")
                    }
                }
                LabeledContent("Identify") {
                    HStack(spacing: directRecorderGap) {
                        KeyboardShortcuts.Recorder("", name: .identifySelection).frame(width: directRecorderWidth)
                        KeyboardShortcuts.Recorder("", name: .identifyFullScreen).frame(width: directRecorderWidth)
                    }
                }
                if draft.lensSearch {
                    LabeledContent("Lens") {
                        HStack(spacing: directRecorderGap) {
                            KeyboardShortcuts.Recorder("", name: .lensSelection).frame(width: directRecorderWidth)
                            KeyboardShortcuts.Recorder("", name: .lensFullScreen).frame(width: directRecorderWidth)
                        }
                    }
                }
                caption("Proofread, Identify, and Lens run straight from a hotkey, skipping "
                    + "the toolbar. For the two-column ones, Selection lets you drag a box first while "
                    + "Full screen grabs the whole display; Proofread always runs on a selection. "
                    + "Turn on Lens in Privacy to assign its shortcuts.")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $draft.launchAtLogin)
            }
            Section("Appearance") {
                Picker("Toolbar", selection: $draft.actionBarStyle) {
                    ForEach(ActionBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                caption("Compact shows icons only; Comfortable shows icons with names.")
                Toggle("Hide unavailable actions", isOn: $draft.hideUnavailable)
                caption("When off, unavailable actions stay visible but greyed out.")
                Toggle("Color-code actions", isOn: $draft.colorfulActions)
                caption("Tints each toolbar action a distinct color so features are easier to "
                    + "recognize. Off by default.")
            }
            Section("Privacy") {
                Toggle("Local-only mode", isOn: $draft.localOnly)
                caption("Blocks all network calls except your chosen model. Best for work Macs.")
                Toggle("Search with Lens", isOn: $draft.lensSearch)
                    .disabled(draft.localOnly)
                caption("Adds a Lens action that uploads the selection to Google and shows the "
                    + "visual matches in a panel next to it. Off by default — it leaves your Mac, and "
                    + "is paused in local-only mode.")
            }
            Section("Translation") {
                Toggle("Pre-translate selections", isOn: $draft.pretranslate)
                caption("Translates in the background so Translate is instant.")
            }
            Section("Chat history") {
                Button("Clear chat history…", role: .destructive) { showClearHistoryConfirm = true }
                caption("Conversations are saved on this Mac (in Application Support) so they survive "
                    + "app updates. They never leave your device. This deletes them all.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all saved conversations?", isPresented: $showClearHistoryConfirm,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { ChatController.shared.clearAllHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved chat from this Mac. This can't be undone.")
        }
    }

    // MARK: - Intelligence

    /// Three instances of one template, plus the Ollama plumbing card. Nothing here declares a row
    /// order, a label width, a control width or a spacing value — those live in `ModelProviderSection`
    /// and `SettingsMetrics`, so a layout fix is one edit for all three (and for the next one).
    private var intelligenceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                languageSection
                imageSection
                embeddingSection
                // Ollama plumbing shown once, only when text OR image actually uses Ollama.
                if usesOllama { ollamaSection }
            }
            .padding(SettingsMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsPalette.pageFill)
        // Anthropic catalogs load when switching to those cloud engines (Ollama loads in `load()`;
        // the OpenAI-compatible connections load their models on add/edit/refresh).
        .onChange(of: draft.provider) { _, _ in Task { await loadCloudModels() } }
        .onChange(of: draft.visionEngine) { _, _ in Task { await loadVisionModels() } }
        .onChange(of: draft.embeddingProvider) { _, _ in refreshEmbeddingStatus() }
        .onChange(of: draft.embeddingOllamaModel) { _, _ in refreshEmbeddingStatus() }
        .onChange(of: draft.embeddingSelection) { _, _ in refreshEmbeddingStatus() }
        // Keep a linked Image section live: when the language selection changes, what Inherit
        // resolves to (and the embedding status) has to follow along.
        .onChange(of: draft.langSelection) { _, _ in refreshEmbeddingStatus() }
        .task {
            scheduleOllamaStatus(); await loadVisionModels(); refreshEmbeddingStatus()
        }
        .sheet(isPresented: $showConnections) { connectionsSheet }
        .alert("Re-add your language model", isPresented: $showMigrationNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Intelligence settings format changed in this update. Your OpenAI-compatible "
                 + "connection needs to be re-added under Language model — add it again as a "
                 + "connection to restore it.")
        }
    }

    private var connectionsSheet: some View {
        ConnectionsSheet(
            registry: $draft.registry,
            keyValues: $registryKeyValues,
            discovering: discoveringKeyIDs,
            discover: { id in Task { await discoverModels(forKeyID: id) } },
            onChanged: { connectionsDidChange() },
            dismiss: { showConnections = false },
            primary: draftPrimaryRef)
    }

    // MARK: - The three model sections (one template, three instances)

    private var languageSection: some View {
        ModelProviderSection(
            title: "Language model",
            providers: availableProviders.map { ProviderChoice(id: $0.rawValue, label: $0.label) },
            providerID: Binding(get: { draft.provider.rawValue },
                                set: { draft.provider = ProviderKind(rawValue: $0) ?? .onDevice }),
            providerCaption: draft.provider == .openAICompatible
                ? "Your configured endpoints, each with its own provider" : nil,
            showsModelRow: draft.provider != .onDevice,
            modelCaption: draft.provider == .openAICompatible
                ? "Available from all configured connections" : nil,
            modelControl: {
                switch draft.provider {
                case .onDevice:
                    EmptyView()
                case .ollama:
                    ollamaModelControl(selection: $draft.ollamaModel)
                case .mlx:
                    mlxModelControl
                case .openAICompatible:
                    registryModelControl(for: .language)
                case .anthropic:
                    cloudModelControl(selection: $draft.anthropicModel, models: anthropicModels) {
                        await loadCloudModels(); return !anthropicModels.isEmpty
                    }
                }
            },
            extras: {
                if draft.provider == .mlx {
                    if mlxIsCustom {
                        SettingsRow("Model ID") {
                            TextField("", text: $draft.mlxModel, prompt: Text(MLXProvider.defaultModelID))
                                .textFieldStyle(.roundedBorder)
                                .settingsFieldWidth()
                        }
                    }
                    mlxDownloadRow
                }
                if draft.provider == .openAICompatible || draft.provider == .anthropic {
                    autoFallbackRow
                    if draft.autoFallback, !draft.localOnly { slowModelRow }
                }
            },
            contextControl: {
                if draft.provider == .openAICompatible { registryContextControl() }
            },
            connections: draft.provider == .openAICompatible ? connectionsRowConfig : nil,
            apiKey: languageAPIKey,
            test: languageTest,
            footnote: draft.provider == .openAICompatible ? registryLanguageHint : privacyLine)
    }

    private var imageSection: some View {
        ModelProviderSection(
            title: "Image model",
            // "Same as language model" is not a protocol — it's the Inherit switch, so the same
            // intent can't be expressed twice.
            providers: availableVisionEngines.filter { $0 != .matchText }
                .map { ProviderChoice(id: $0.rawValue, label: $0.label) },
            providerID: Binding(get: { draft.visionEngine.rawValue },
                                set: { draft.visionEngine = VisionEngine(rawValue: $0) ?? .ollama }),
            inheritance: InheritanceConfig(
                title: "Inherit language model",
                isOn: Binding(get: { draft.visionEngine == .matchText },
                              set: { setImageInheritsLanguage($0) }),
                note: draft.visionEngine == .matchText
                    ? "Images go to whatever the language model runs"
                    : "Images use their own protocol and model"),
            showsModelRow: draft.visionEngine != .mlx,
            modelCaption: draft.visionEngine == .openAICompatible
                ? "Available from all configured connections" : nil,
            modelControl: {
                switch draft.visionEngine {
                case .matchText, .mlx:
                    EmptyView()
                case .ollama:
                    ollamaModelControl(selection: $draft.visionModel)
                case .openAICompatible:
                    registryModelControl(for: .vision)
                case .anthropic:
                    cloudModelControl(selection: $draft.visionAnthropicModel,
                                      models: visionAnthropicModels) {
                        await loadVisionModels(); return !visionAnthropicModels.isEmpty
                    }
                }
            },
            extras: {
                if draft.visionEngine == .mlx {
                    MLXModelManager(modelID: $draft.visionMLXModel,
                                    suggestions: Self.mlxVisionSuggestions,
                                    defaultID: MLXVisionProvider.defaultModelID,
                                    localOnly: draft.localOnly)
                }
            },
            contextControl: { EmptyView() },
            connections: draft.visionEngine == .openAICompatible ? connectionsRowConfig : nil,
            apiKey: imageAPIKey,
            test: nil,
            footnote: imageModelHint)
    }

    private var embeddingSection: some View {
        ModelProviderSection(
            title: "Embedding model",
            providers: availableEmbeddingProviders.map { ProviderChoice(id: $0.rawValue, label: $0.label) },
            providerID: Binding(get: { draft.embeddingProvider.rawValue },
                                set: { draft.embeddingProvider = EmbeddingProviderKind(rawValue: $0) ?? .automatic }),
            showsModelRow: draft.embeddingProvider == .ollama || draft.embeddingProvider == .openAICompatible,
            modelCaption: draft.embeddingProvider == .openAICompatible
                ? "Available from all configured connections" : nil,
            modelControl: {
                switch draft.embeddingProvider {
                case .automatic, .apple, .mlx:
                    EmptyView()
                case .ollama:
                    embeddingOllamaControl
                case .openAICompatible:
                    registryModelControl(for: .embedding)
                }
            },
            extras: {
                if draft.embeddingProvider == .mlx {
                    // Same downloadable picker as the Language/Image MLX models — but routed through
                    // the embedder loader (embedding models are BERT-style encoders, not causal LMs).
                    MLXModelManager(modelID: $draft.embeddingMLXModel,
                                    suggestions: MLXEmbeddings.suggestions,
                                    defaultID: MLXEmbeddings.defaultModelID,
                                    localOnly: draft.localOnly,
                                    ensureDownloaded: { try await MLXEmbeddings.ensureDownloaded($0, progress: $1) })
                }
                // MLX shows its own install/error state in its rows above, so the extra status line
                // would be redundant (and could go stale after a download).
                if draft.embeddingProvider != .mlx, let status = embeddingStatus {
                    SettingsRow("Status", caption: status.text) {
                        Image(systemName: status.ok ? "checkmark.circle.fill"
                                                    : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.ok ? Color.green : Color.orange)
                    }
                }
            },
            contextControl: { EmptyView() },
            connections: draft.embeddingProvider == .openAICompatible ? connectionsRowConfig : nil,
            apiKey: nil,
            test: nil,
            footnote: embeddingHint)
    }

    /// Free-model fallback. Only offered for a cloud language model: a local choice never falls back to
    /// the cloud, so the switch would promise something that can't happen.
    /// How long a slow model gets before a free one races it. A race, not a hand-over: the selected model
    /// keeps going and still wins if it starts answering first.
    private var slowModelRow: some View {
        SettingsRow("Slow model", caption: draft.fallbackRaceAfter == 0
                    ? "Wait for your model however long it takes."
                    : "If your model hasn't started answering by then, the best free model starts too. "
                      + "The first to answer wins.") {
            Picker("", selection: $draft.fallbackRaceAfter) {
                ForEach(IntelligenceCoordinator.raceAfterChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Never" : "After \(seconds) s").tag(seconds)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var autoFallbackRow: some View {
        SettingsRow("Fallback", caption: autoFallbackCaption) {
            HStack(spacing: 10) {
                if draft.autoFallback, !draft.localOnly, !draft.registry.entries.isEmpty {
                    if discoveringKeyIDs.isEmpty {
                        Button { Task { await refreshAllKeys() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Check connections for free models again")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                SettingsSwitch(title: "Free models", isOn: $draft.autoFallback,
                               info: "If your model is rate limited, down, or withdrawn before it answers, "
                                   + "Lasso retries on the closest free model from the connections you set to "
                                   + "Use as fallback that can handle the request, then on-device. That sends "
                                   + "the request to a different provider, and free plans may use requests to "
                                   + "improve their models. The reply says which model answered; your selected "
                                   + "model doesn't change.")
                    .disabled(draft.localOnly)
            }
        }
    }

    private var autoFallbackCaption: String {
        if draft.localOnly { return "Paused in local-only mode." }
        guard draft.autoFallback else { return "Retry on a free model when yours is unavailable." }
        if !discoveringKeyIDs.isEmpty { return "Checking connections for free models…" }
        guard !draft.registry.entries.isEmpty else { return "Add a connection to find free models." }
        return Self.autoFallbackStatus(registry: draft.registry, primary: draftPrimaryRef, now: Date())
    }

    /// The registry model the draft's language selection points at, when it's a connection's model.
    private var draftPrimaryRef: ModelRef? {
        guard draft.provider == .openAICompatible, case .model(let keyID, let name) = draft.langSelection
        else { return nil }
        return ModelRef(keyID: keyID, model: name)
    }

    /// The Fallback caption once the feature is on: what the pool holds, then what would change it.
    /// Pure, so the wording (and its single trailing period) is tested rather than eyeballed.
    static func autoFallbackStatus(registry: KeysRegistry, primary: ModelRef?, now: Date) -> String {
        let summary = FreeModelPool.summary(of: registry, primary: primary)
        var sentences: [String] = []
        if summary.models == 0 {
            sentences.append("No free models found")
        } else {
            var first = "\(summary.models) free model\(summary.models == 1 ? "" : "s") across "
                + "\(summary.connections) connection\(summary.connections == 1 ? "" : "s")"
            if let checked = summary.oldestCheck {
                first += " · checked " + RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: now)
            }
            sentences.append(first)
        }
        // Say which connections are left out and what would change that, instead of a count that
        // looks like a bug: one sentence for the switches to turn on, one for providers without a rule.
        let idle = FreeModelPool.nonContributing(in: registry)
        func names(_ entries: [RegisteredKey]) -> String {
            ListFormatter.localizedString(byJoining: entries.map(\.name))
        }
        var switches: [String] = []
        if !idle.notOptedIn.isEmpty { switches.append("Use as fallback for \(names(idle.notOptedIn))") }
        if !idle.needsFreeTier.isEmpty { switches.append("Free tier for \(names(idle.needsFreeTier))") }
        if !switches.isEmpty {
            sentences.append("Turn on " + switches.joined(separator: ", and ") + " in Manage connections")
        }
        if !idle.unsupported.isEmpty {
            sentences.append("Lasso can't detect free models on \(names(idle.unsupported)) yet")
        }
        // A Free tier key that the selected model is billing: its "free" plan models would be billed too.
        for id in FreeModelPool.billedConnections(in: registry, primary: primary).sorted() {
            guard let entry = registry.key(withID: id) else { continue }
            sentences.append("\(entry.name) is marked Free tier but your selected model there is paid-only, "
                             + "so the key is billed")
        }
        return sentences.joined(separator: ". ") + "."
    }

    /// Ollama's server plumbing. Not a model-type section, so not an instance of the template — but it
    /// is built from the same row primitive, so its grid matches the three above exactly.
    private var ollamaSection: some View {
        SettingsCard(title: "Ollama") {
            SettingsRow("Server") {
                TextField("", text: $draft.ollamaBaseURL, prompt: Text("Auto — localhost:11434"))
                    .textFieldStyle(.roundedBorder)
                    .settingsFieldWidth()
                    .onChange(of: draft.ollamaBaseURL) { _, _ in scheduleOllamaStatus() }
            }
            SettingsRow("Status") { ollamaStatusCaption }
            if OllamaLauncher.isInstalled {
                SettingsRow("On launch") {
                    SettingsSwitch(title: "Start with Lasso", isOn: $draft.ollamaAutoStart)
                }
            }
        }
    }

    // MARK: Section slot contents

    /// Anthropic is a single-endpoint protocol, so its credential stays inline. OpenAI-compatible has
    /// no key row at all: a key belongs to a connection, and connections live in the manager.
    private var languageAPIKey: APIKeyRowConfig? {
        guard draft.provider == .anthropic else { return nil }
        return APIKeyRowConfig(value: $draft.anthropicKey,
                               caption: "Stored in your Mac's Keychain.",
                               onClear: { draft.anthropicKey = "" })
    }

    private var imageAPIKey: APIKeyRowConfig? {
        guard draft.visionEngine == .anthropic else { return nil }
        return APIKeyRowConfig(value: $draft.visionAnthropicKey,
                               caption: "Stored in your Mac's Keychain.",
                               onClear: { draft.visionAnthropicKey = "" })
    }

    private var languageTest: TestRowConfig? {
        switch draft.provider {
        case .openAICompatible:
            // Many-connection protocol: the Connections row tests all of them instead.
            return nil
        case .mlx:
            // Nothing to test until the model is on disk.
            guard MLXProvider.isDownloaded(draft.mlxModel) else { return nil }
            return TestRowConfig(outcome: testState, successText: nil, run: { runTest() },
                                 note: "On this Mac")
        default:
            return TestRowConfig(outcome: testState, successText: nil, run: { runTest() }, note: nil)
        }
    }

    // MARK: Inheritance (Image ← Language)

    /// What the Image section resolves to while it's linked — shown instead of a second, independent
    /// copy of the Provider / Keys / Model rows.
    private var inheritedImageSummary: String {
        var parts = [draft.provider.label]
        switch draft.provider {
        case .onDevice:
            parts.append("text-only — images need their own provider")
        case .ollama:
            parts.append(draft.ollamaModel.isEmpty ? "Auto" : draft.ollamaModel)
        case .mlx:
            parts.append(draft.mlxModel)
        case .anthropic:
            parts.append(draft.anthropicModel)
        case .openAICompatible:
            if let resolved = resolveRegistrySelection(draft.langSelection, capability: .language) {
                parts.append(resolved.model)
                if let key = resolved.key { parts.append("via “\(key.name)”") }
            } else {
                parts.append("no model selected")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Break or restore the link. Unlinking keeps the value it was showing — the standard macOS
    /// linked-value behaviour — so turning it off is a starting point, not a reset.
    private func setImageInheritsLanguage(_ on: Bool) {
        guard !on else { draft.visionEngine = .matchText; return }
        let mapped: VisionEngine
        switch draft.provider {
        case .ollama: mapped = .ollama
        case .mlx: mapped = .mlx
        case .openAICompatible: mapped = .openAICompatible
        case .anthropic: mapped = .anthropic
        case .onDevice: mapped = .ollama    // Apple's model is text-only; nearest image-capable default
        }
        let choices = availableVisionEngines.filter { $0 != .matchText }
        draft.visionEngine = choices.contains(mapped) ? mapped : (choices.first ?? .ollama)
        switch draft.visionEngine {
        case .ollama:
            if draft.visionModel.isEmpty { draft.visionModel = draft.ollamaModel }
        case .openAICompatible:
            draft.visionSelection = concreteCopy(of: draft.langSelection)
            healSelection(.vision)
        default:
            break
        }
    }

    /// Resolve a selection to a standalone value, so a copied selection doesn't secretly stay linked.
    private func concreteCopy(of selection: ModelSelection) -> ModelSelection {
        guard let resolved = resolveRegistrySelection(selection, capability: .language) else { return .none }
        if let key = resolved.key { return .model(keyID: key.id, name: resolved.model) }
        return .manual(name: resolved.model)
    }

    private func refreshEmbeddingStatus() {
        let choice = draft.embeddingProvider
        let ollamaModel = draft.embeddingOllamaModel
        let mlxModel = draft.embeddingMLXModel
        embeddingStatusTask?.cancel()
        embeddingStatusTask = Task {
            // Debounce: while the user types a model name we don't want to hit the cloud /embeddings
            // endpoint (or re-probe Ollama) on every keystroke.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let status = await probeEmbedding(choice, ollamaModel: ollamaModel, mlxModel: mlxModel)
            if !Task.isCancelled { embeddingStatus = status }
        }
    }

    /// Probe the chosen backend and describe the *actual* outcome — including the always-Apple fallback,
    /// so the user knows exactly what their chat memory is doing.
    private func probeEmbedding(_ choice: EmbeddingProviderKind, ollamaModel: String,
                                mlxModel: String) async -> (ok: Bool, text: String) {
        let apple = AppleSentenceEmbedder()
        let appleNote = "chat memory will use the running summary only (semantic recall off)"

        func ollamaEmbeds(_ model: String) async -> Bool {
            guard await OllamaEndpoint.isReachable(OllamaEndpoint.baseURL, maxAge: 30) else { return false }
            return (await OllamaChatEmbedder(model: model).embed(["probe"]))?.first?.isEmpty == false
        }

        switch choice {
        case .apple:
            return apple.isAvailable
                ? (true, "Active — \(apple.label). Runs on this Mac.")
                : (false, "Not available on this Mac for this language — \(appleNote).")

        case .automatic:
            if await ollamaEmbeds("nomic-embed-text") {
                return (true, "Active — Ollama nomic-embed-text (local).")
            }
            return apple.isAvailable
                ? (true, "Active — \(apple.label). Upgrades to Ollama automatically if you run it.")
                : (false, "No embedder available — \(appleNote).")

        case .ollama:
            // "Auto" → the best installed embedding model, so the probe targets the real one.
            let model = ollamaModel.isEmpty
                ? (availableModels.first(where: OllamaModels.isEmbedding) ?? "nomic-embed-text")
                : ollamaModel
            if await ollamaEmbeds(model) { return (true, "Active — Ollama \(model) (local).") }
            return apple.isAvailable
                ? (true, "Ollama \(model) not reachable — using Apple on-device instead.")
                : (false, "Ollama \(model) not reachable and no on-device embedder — \(appleNote).")

        case .mlx:
            let model = mlxModel.isEmpty ? MLXEmbeddings.defaultModelID : mlxModel
            let short = model.components(separatedBy: "/").last ?? model
            if !MLXEmbeddings.isDownloaded(model) {
                return (false, "MLX \(short) isn't downloaded yet — download it below (using Apple on-device until then).")
            }
            let ok = (await MLXEmbeddings.embed(["probe"], modelID: model))?.first?.isEmpty == false
            if ok { return (true, "Active — MLX \(short) (local, on-device).") }
            return apple.isAvailable
                ? (true, "MLX \(short) couldn't run — using Apple on-device instead.")
                : (false, "MLX \(short) couldn't run and no on-device embedder — \(appleNote).")

        case .openAICompatible:
            // Resolve the embedding card's selection through the shared registry: which key backs the
            // chosen model, and does it need (and have) an API key. "Same as language" is nonsensical
            // for a dedicated embedder, so it resolves to the embedding selection directly.
            guard let resolved = resolveRegistrySelection(draft.embeddingSelection, capability: .embedding) else {
                return apple.isAvailable
                    ? (true, "No embedding model selected yet — using Apple on-device instead.")
                    : (false, "No embedding model selected and no on-device embedder — \(appleNote).")
            }
            let model = resolved.model
            guard let entry = resolved.key else {
                // Manually-added model with no backing key — can't probe an endpoint.
                return apple.isAvailable
                    ? (true, "Manual model “\(model)” has no registered key — using Apple on-device instead.")
                    : (false, "Manual model “\(model)” has no registered key — \(appleNote).")
            }
            let key = registryKeyValue(entry.id)
            if !entry.keyNotRequired, key.isEmpty {
                return apple.isAvailable
                    ? (true, "“\(entry.name)” needs a key — using Apple on-device instead.")
                    : (false, "“\(entry.name)” needs a key and no on-device embedder — \(appleNote).")
            }
            let embedder: ChatEmbedder = entry.kind == .gemini
                ? GeminiEmbedder(apiKey: key, model: model)
                : OpenAIEmbedder(baseURL: URL(string: entry.baseURL)
                                 ?? URL(string: "https://api.openai.com/v1")!,
                                 apiKey: key, model: model)
            let ok = (await embedder.embed(["probe"]))?.first?.isEmpty == false
            if ok {
                return (true, "Active — cloud \(model) via “\(entry.name)”. Conversation text is sent to your provider.")
            }
            return apple.isAvailable
                ? (true, "Cloud \(model) didn't return embeddings (check the endpoint + model) — using Apple on-device instead.")
                : (false, "Cloud \(model) failed and no on-device embedder — \(appleNote).")
        }
    }

    /// Image providers offered — cloud hidden in local-only mode (keyed to the saved setting, like the
    /// text engine list, so it only changes after Save & Apply).
    private var availableVisionEngines: [VisionEngine] {
        saved.localOnly ? [.matchText, .ollama, .mlx] : VisionEngine.allCases
    }

    /// Whether the Ollama config block is relevant: either role uses Ollama, or Apple text falls back
    /// to local Ollama for images.
    private var usesOllama: Bool {
        draft.provider == .ollama || draft.visionEngine == .ollama
    }

    /// Embedding backends offered — cloud hidden in local-only mode (keyed to the saved setting, like
    /// the text/image lists, so it only changes after Save & Apply).
    private var availableEmbeddingProviders: [EmbeddingProviderKind] {
        saved.localOnly ? [.automatic, .apple, .ollama, .mlx] : EmbeddingProviderKind.allCases
    }

    /// Ollama embedding model control: a picker of *installed embedding models* (filtered from the
    /// same catalog the Language row uses) + a refresh button, matching that row's behaviour. Falls
    /// back to a manual field when none are installed yet (so the user can still name one to pull).
    @ViewBuilder private var embeddingOllamaControl: some View {
        let embedModels = availableModels.filter(OllamaModels.isEmbedding)
        HStack(spacing: 8) {
            if embedModels.isEmpty {
                TextField("", text: $draft.embeddingOllamaModel, prompt: Text("nomic-embed-text"))
                    .textFieldStyle(.roundedBorder)
                    .settingsFieldWidth()
            } else {
                Picker("", selection: $draft.embeddingOllamaModel) {
                    Text("Auto").tag("")
                    let current = draft.embeddingOllamaModel
                    // Only flag a truly-missing explicit choice — treat a tag-less name as matching
                    // Ollama's implicit ":latest" so "nomic-embed-text" isn't falsely "not installed".
                    if !current.isEmpty, !embedModels.contains(current),
                       !embedModels.contains(current + ":latest") {
                        Text("\(current) (not installed)").tag(current)
                    }
                    ForEach(embedModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            refreshModelsButton
        }
    }

    /// One refresh affordance, reused by every Ollama-backed model control.
    private var refreshModelsButton: some View {
        Button { reloadOllamaModels() } label: {
            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Refresh installed models")
    }

    /// Explanatory caption for the chosen embedding backend.
    private var embeddingHint: String {
        switch draft.embeddingProvider {
        case .automatic:
            return "Recalls relevant earlier messages in long chats. Uses a local Ollama embed model if "
                + "you have one, otherwise Apple's built-in on-device embeddings — no download needed."
        case .apple:
            return "Apple's built-in on-device embeddings (NaturalLanguage) — bundled with macOS, no "
                + "download. Uses sentence embeddings where available, otherwise word embeddings, so it "
                + "works on nearly any Mac. Instant and never leaves your device."
        case .ollama:
            return "A local Ollama embedding model — higher quality and multilingual. Install once with "
                + "`ollama pull \(draft.embeddingOllamaModel.isEmpty ? "nomic-embed-text" : draft.embeddingOllamaModel)` "
                + "(~275 MB). Falls back to Apple on-device if it's unavailable."
        case .mlx:
            return "A local, Apple-Silicon embedding model (e5 / bge), downloaded in-app — strong and "
                + "multilingual, no Ollama. Uses Apple on-device until it's downloaded."
        case .openAICompatible:
            return "Cloud embeddings from an OpenAI-compatible service of your choice (e.g. "
                + "text-embedding-3-small or -large) — pick a service that serves /embeddings, which may "
                + "differ from your Language model. ⚠️ Conversation text is sent to that provider to be "
                + "embedded; this option is hidden in local-only mode."
        }
    }

    // MARK: - Connectors (the "bring your own tool" store)

    private var connectorsTab: some View {
        Form {
            if draft.localOnly {
                Section {
                    Label("Connectors are paused in local-only mode. Turn it off in General to use them.",
                          systemImage: "lock.shield.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                connectorList([Connectors.webSearch])
            } header: {
                Text("Web context (on by default, no setup)")
            } footer: {
                caption("Free public text search (Wikipedia, DuckDuckGo, Reddit) over plain HTTP — used to "
                        + "ground Identify and Chat. No account, no key.")
            }

            Section {
                DisclosureGroup("Advanced — bring your own search key") {
                    connectorList(Connectors.advanced)
                }
            } footer: {
                caption("Optional: paste a Tavily or SerpApi key for stronger, ranked web results. "
                        + "Most people never need these — the free web search above already grounds answers.")
            }

            Section {
                Label("To identify what's in a photo, use Search with Google Lens (a one-tap button in "
                      + "the Identify card). Turn it on under General ▸ Privacy — it's opt-in because it "
                      + "uploads the image to Google.",
                      systemImage: "photo.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                caption("Everything here is optional — Lasso works with nothing connected: Apple "
                        + "Intelligence, OCR and Translate run on-device. Your AI model is chosen on the "
                        + "Intelligence tab; keys are stored in the Keychain.")
            }
        }
        .formStyle(.grouped)
    }

    private func connectorList(_ connectors: [Connector]) -> some View {
        ForEach(connectors) { connector in
            ConnectorCard(connector: connector,
                          enabled: enabledBinding(connector.id),
                          key: keyBinding(connector.id),
                          localOnly: draft.localOnly)
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.connectorEnabled[id] ?? false },
                set: { draft.connectorEnabled[id] = $0 })
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(get: { draft.connectorKeys[id] ?? "" },
                set: { draft.connectorKeys[id] = $0 })
    }

    /// Engines offered in the picker — cloud options are hidden in local-only mode (Apple/Ollama
    /// only). Keyed to the *saved* setting so it only changes after Save & Apply, not while editing.
    private var availableProviders: [ProviderKind] {
        saved.localOnly ? [.onDevice, .ollama, .mlx] : ProviderKind.allCases
    }

    /// The Language section's MLX model control. A Menu (not Picker) so there's no leading selection
    /// check; each item shows a filled (downloaded) / outline (available) download icon.
    private var mlxModelControl: some View {
        Menu {
            // Downloaded models first, then the rest.
            ForEach(mlxDownloadedSuggestions, id: \.id) { mlxMenuItem($0) }
            if !mlxDownloadedSuggestions.isEmpty, !mlxAvailableSuggestions.isEmpty { Divider() }
            ForEach(mlxAvailableSuggestions, id: \.id) { mlxMenuItem($0) }
            Divider()
            Button("Custom…") {
                if Self.mlxSuggestionIDs.contains(draft.mlxModel) { draft.mlxModel = "" }
            }
        } label: {
            Text(mlxMenuLabel)
        }
        .fixedSize()
        .onAppear { refreshMLXInstalled(); refreshMLXRemoteSize() }
        .onChange(of: draft.mlxModel) { mlxDownload = .idle; refreshMLXRemoteSize() }
    }

    /// Fetch the image provider's cloud model catalog into its picker (Anthropic only — the
    /// OpenAI-compatible catalog comes from the shared registry, populated per-key on register).
    private func loadVisionModels() async {
        switch draft.visionEngine {
        case .anthropic:
            let url = URL(string: draft.visionAnthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            visionAnthropicModels = await AnthropicProvider.availableModels(
                baseURL: url, apiKey: draft.visionAnthropicKey)
        default:
            break
        }
    }

    /// Live Ollama reachability — the visible signal users need (the compiled app has no console).
    @ViewBuilder
    private var ollamaStatusCaption: some View {
        if let status = ollamaStatus {
            HStack(spacing: 8) {
                Label(status.label, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(status.ok ? Color.green : Color.orange)
                if !status.ok, OllamaLauncher.isInstalled {
                    Button("Start") {
                        ollamaStatus = nil
                        Task { await OllamaLauncher.start(); scheduleOllamaStatus() }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else {
            caption("Checking for Ollama…")
        }
    }

    /// Debounced reachability probe for the *staged* server URL, so the caption reflects what the
    /// user is typing before they Save.
    private func scheduleOllamaStatus() {
        ollamaStatus = nil
        let staged = draft.ollamaBaseURL
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard staged == draft.ollamaBaseURL else { return }   // superseded by newer keystrokes
            let status = await OllamaEndpoint.status(for: staged)
            ollamaStatus = status
            if status.ok {   // server's up — (re)load the installed model list
                availableModels = await OllamaModels.installed()
                modelsLoaded = true
                await intelligence.refreshVisionAvailability()
            }
        }
    }

    /// Manually re-fetch the installed Ollama models (e.g. after starting Ollama or pulling a model).
    private func reloadOllamaModels() {
        Task {
            availableModels = await OllamaModels.installed()
            modelsLoaded = true
            ollamaStatus = await OllamaEndpoint.status(for: draft.ollamaBaseURL)
            await intelligence.refreshVisionAvailability()
        }
    }

    /// Cloud model selector — same native pop-up as the Ollama model list, at the same width, for a
    /// uniform design. Auto-loads the provider's catalog (with a reload button); falls back to a text
    /// field when there's no catalog yet (no key, or an endpoint that doesn't expose `/models`).
    @ViewBuilder
    private func cloudModelControl(selection: Binding<String>, models: [String], isLocal: Bool = false,
                                   reload: @escaping () async -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            if models.isEmpty {
                TextField("", text: selection, prompt: Text("type a model name"))
                    .textFieldStyle(.roundedBorder)
                    .settingsFieldWidth()
            } else {
                Picker("", selection: selection) {
                    let current = selection.wrappedValue
                    if current.isEmpty {
                        Text("Select a model…").tag("")
                    } else if !models.contains(current) {
                        Text("\(current) (custom)").tag(current)
                    }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            reloadButton(reload, isLocal: isLocal)
        }
        if let modelLoadNote {
            Text(modelLoadNote).font(SettingsFont.sub).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    @ViewBuilder
    private func reloadButton(_ reload: @escaping () async -> Bool, isLocal: Bool = false) -> some View {
        Button {
            Task {
                loadingModels = true; modelLoadNote = nil
                let found = await reload()
                loadingModels = false
                // A local server needs no key (see OpenAICompatibleProvider.checkAvailability), so don't
                // send the user hunting for an API key that was never required.
                modelLoadNote = found ? nil : (isLocal
                    ? "No models returned — check the base URL and that the server is running."
                    : "No models returned — check the base URL and API key.")
            }
        } label: {
            if loadingModels { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
        }
        .buttonStyle(.borderless)
        .help("Load available models")
        .disabled(loadingModels)
    }

    /// Fetch the active cloud provider's model catalog into its picker (Anthropic only — the
    /// OpenAI-compatible catalog comes from the shared registry).
    private func loadCloudModels() async {
        switch draft.provider {
        case .anthropic:
            let url = URL(string: draft.anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            anthropicModels = await AnthropicProvider.availableModels(
                baseURL: url, apiKey: draft.anthropicKey)
        default:
            break
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            // OpenAI-compatible is covered by the Connections row test; the shared row only runs
            // for the other providers, so empty OpenAI params are fine here.
            testState = await ConnectionTest.run(
                provider: draft.provider,
                openAIBaseURL: "", openAIKey: "", openAIModel: "",
                anthropicBaseURL: draft.anthropicBaseURL, anthropicKey: draft.anthropicKey,
                anthropicModel: draft.anthropicModel)
        }
    }

    /// Explains where Identify sends images, given the chosen image provider (and, for "Same as text
    /// engine", what the text engine can actually do).
    private var imageModelHint: String {
        switch draft.visionEngine {
        case .matchText:
            switch draft.provider {
            case .onDevice:
                return "Apple Intelligence is text-only and can’t see images — choose “Ollama (local)” "
                    + "or a cloud image provider for Identify."
            case .ollama:
                return "Images use your Ollama model if it’s multimodal, else your best installed vision model."
            case .mlx:
                return MLXProvider.isVision(draft.mlxModel)
                    ? "Your MLX model is a vision-language model, so it handles images too — one local model for both."
                    : "Your MLX language model can’t see images — pick a vision-language model above, or choose a dedicated image provider below."
            case .openAICompatible:
                return "Images go to your \(serviceName(resolvedLanguageBaseURL)) language model — it must be "
                    + "multimodal. Otherwise pick a dedicated image provider below."
            case .anthropic:
                return "Images go to your Anthropic language model — use a vision Claude, or pick a "
                    + "dedicated image provider below."
            }
        case .ollama:
            return "Images are identified locally by Ollama — nothing leaves your Mac."
        case .mlx:
            return "Images are identified locally by a native MLX vision model — nothing leaves your Mac."
        case .openAICompatible:
            return "Images are sent to \(serviceName(resolvedVisionBaseURL)) — use a multimodal "
                + "model (e.g. gpt-4o)."
        case .anthropic:
            return "Images are sent to Anthropic — use a vision Claude model (e.g. claude-3-5-sonnet)."
        }
    }

    // MARK: - Omni-router registry (shared Keys UI + merged model list)

    /// Base URL of the key backing the current language selection (for privacy/hint copy).
    private var resolvedLanguageBaseURL: String {
        resolveRegistrySelection(draft.langSelection, capability: .language)?.key?.baseURL ?? ""
    }
    private var resolvedVisionBaseURL: String {
        resolveRegistrySelection(draft.visionSelection, capability: .vision)?.key?.baseURL ?? ""
    }

    /// Live API-key value for a registered key (edited in `registryKeyValues`, seeded from Keychain).
    private func registryKeyValue(_ keyID: String) -> String { registryKeyValues[keyID] ?? "" }

    /// The selection binding for a card's capability.
    private func selectionBinding(_ capability: ModelCapability) -> Binding<ModelSelection> {
        switch capability {
        case .language: return $draft.langSelection
        case .vision: return $draft.visionSelection
        case .embedding: return $draft.embeddingSelection
        }
    }

    /// Resolve a card's selection to a concrete model name + its backing key. `.sameAsLanguage`
    /// chases the language selection (so image/embedding follow it live). Returns nil when nothing
    /// resolvable is selected (empty state / dangling reference cleared).
    private func resolveRegistrySelection(_ selection: ModelSelection,
                                          capability: ModelCapability) -> (model: String, key: RegisteredKey?)? {
        switch selection {
        case .none:
            return nil
        case .sameAsLanguage:
            // Track the language card; guard against a self-referential loop.
            if case .sameAsLanguage = draft.langSelection { return nil }
            return resolveRegistrySelection(draft.langSelection, capability: .language)
        case .manual(let name):
            return name.isEmpty ? nil : (name, draft.registry.enabledKey(exposingModel: name))
        case .model(let keyID, let name):
            guard let entry = draft.registry.key(withID: keyID), entry.enabled,
                  entry.models.contains(where: { $0.name == name }) else {
                // Dangling reference — the key was disabled/removed, or the model vanished on refetch.
                return nil
            }
            return (name, entry)
        }
    }

    /// If a card's selection no longer resolves (key disabled/removed, model gone), fall back to the
    /// first available model for that capability — or clear to `.none` (visible empty state).
    private func healSelection(_ capability: ModelCapability) {
        let binding = selectionBinding(capability)
        // "Same as language" stays valid as long as the language card itself resolves.
        if case .sameAsLanguage = binding.wrappedValue,
           resolveRegistrySelection(.sameAsLanguage, capability: capability) != nil {
            return
        }
        if resolveRegistrySelection(binding.wrappedValue, capability: capability) != nil { return }
        if let first = draft.registry.flatSelectable(for: capability).first {
            binding.wrappedValue = first.keyID.isEmpty
                ? .manual(name: first.model.name)
                : .model(keyID: first.keyID, name: first.model.name)
        } else {
            // Never fall back to `.sameAsLanguage`: following the Language model is the Image
            // section's Inherit switch, not a hidden state of the model picker.
            binding.wrappedValue = .none
        }
    }

    // MARK: Connections (one registry, shared by every section)

    /// The Connections row. Deliberately reports rather than selects: every configured endpoint is
    /// live at once and contributes its models to the Model picker above, so there is nothing here
    /// to choose. Configuring them happens in the manager sheet.
    private var connectionsRowConfig: ConnectionsRowConfig {
        ConnectionsRowConfig(
            summary: connectionsSummary,
            statusText: connectionsStatusText,
            statusTint: connectionsStatusTint,
            isTesting: connectionsTest == .testing,
            canTest: !draft.registry.entries.isEmpty,
            onTest: { runConnectionsTest() },
            onManage: { showConnections = true })
    }

    private var connectionsSummary: String {
        let count = draft.registry.entries.count
        guard count > 0 else { return "None configured" }
        let models = draft.registry.entries.reduce(0) { $0 + $1.models.count }
        return "\(count) configured · \(models) model\(models == 1 ? "" : "s") available"
    }

    private var connectionsStatusText: String {
        switch connectionsTest {
        case .idle: return connectionsTestNote ?? "Not tested"
        case .testing: return "Testing…"
        case .ok: return connectionsTestNote ?? "All connections reachable"
        case .failure(let message): return message
        }
    }

    private var connectionsStatusTint: Color {
        switch connectionsTest {
        case .idle: return .secondary
        case .testing: return .secondary
        case .ok: return .green
        case .failure: return .orange
        }
    }

    /// Test *every* configured connection, because all of them serve models — testing only the one
    /// behind the current selection would leave the rest silently broken until first use.
    private func runConnectionsTest() {
        let entries = draft.registry.entries
        guard !entries.isEmpty else { return }
        connectionsTest = .testing
        connectionsTestNote = nil
        Task {
            let start = Date()
            var failed: [String] = []
            for entry in entries {
                if !(await KeysRegistry.reachable(entry, apiKey: registryKeyValue(entry.id))) {
                    failed.append(entry.name)
                }
            }
            let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
            if failed.isEmpty {
                connectionsTestNote = entries.count == 1
                    ? "Reachable · \(ms) ms"
                    : "All \(entries.count) reachable · \(ms) ms"
                connectionsTest = .ok(ms)
            } else {
                connectionsTest = .failure(failed.count == entries.count
                    ? "None reachable"
                    : "\(failed.joined(separator: ", ")) unreachable")
            }
        }
    }

    /// (Re)discover a connection's models from its endpoint, tag their capabilities, and store them
    /// on the entry. Every section's picker reads the union of these, so one refresh serves all three.
    private func discoverModels(forKeyID keyID: String) async {
        guard let entry = draft.registry.key(withID: keyID) else { return }
        discoveringKeyIDs.insert(keyID)
        defer { discoveringKeyIDs.remove(keyID) }
        let discovered = await KeysRegistry.discoverModels(for: entry, apiKey: registryKeyValue(keyID))
        guard let idx = draft.registry.entries.firstIndex(where: { $0.id == keyID }) else { return }
        // A failed fetch still empties the list here: in Settings, "no models yet" is how a bad key or
        // URL shows itself. Only a successful one counts as a check for the free-model pool.
        draft.registry.entries[idx].models = discovered ?? []
        if discovered != nil { draft.registry.entries[idx].modelsCheckedAt = Date() }
        // Newly discovered models may satisfy a section that was empty; heal selections + status.
        for cap in ModelCapability.allCases { healSelection(cap) }
        refreshEmbeddingStatus()
    }

    /// A connection was added, edited or removed: any section whose selection now dangles falls back,
    /// and a stale reachability result no longer describes the current set.
    private func connectionsDidChange() {
        for cap in ModelCapability.allCases { healSelection(cap) }
        connectionsTest = .idle
        connectionsTestNote = nil
        refreshEmbeddingStatus()
    }

    // MARK: Merged model list (grouped, capability-filtered, searchable)

    /// The merged model list for a section. Closed state is a single "trigger" button ("Select a model
    /// ⌄") sized to the panel's one control width; clicking it opens ONE anchored popover with a
    /// search box on top and the grouped, capability-filtered model list below. The trigger is
    /// disabled until at least one enabled key exposes a model — nothing to pick otherwise.
    private func registryModelControl(for capability: ModelCapability) -> some View {
        let triggerEnabled = !draft.registry.groups(for: capability).isEmpty

        return Button {
            registrySearch[capability] = ""
            modelPickerOpenFor = capability
        } label: {
            HStack(spacing: 6) {
                Text(modelMenuLabel(for: capability))
                    .foregroundStyle(triggerEnabled ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: SettingsMetrics.fieldWidth, minHeight: SettingsMetrics.controlHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!triggerEnabled)
        .popover(isPresented: Binding(
            get: { modelPickerOpenFor == capability },
            set: { if !$0 { modelPickerOpenFor = nil } }),
            arrowEdge: .bottom) {
            modelPickerPanel(for: capability)
        }
    }

    /// The opened picker panel: search box pinned at top, grouped model list below, then the
    /// manual-entry and refresh affordances. There is deliberately no "Same as language model" entry:
    /// following another section is the Inherit switch's job, and one intent gets one control.
    @ViewBuilder
    private func modelPickerPanel(for capability: ModelCapability) -> some View {
        let groups = filteredGroups(for: capability)
        let selection = selectionBinding(capability).wrappedValue
        // Free status as the pool judges it (provider rules, Free tier, a billed key), but describing the
        // model: unlike the pool, it doesn't depend on the connection's "Use as fallback".
        let badges = FreeModelPool.badges(in: draft.registry, primary: draftPrimaryRef)

        VStack(spacing: 0) {
            TextField("Search models", text: searchBinding(capability))
                .textFieldStyle(.plain)
                .padding(8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty {
                        Text(draft.registry.entries.isEmpty
                             ? "No connections yet — add one to discover models"
                             : "No models found on your connections")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }

                    // One group per connection: the list is the union of every endpoint's models, and
                    // the header is what tells you where a model will actually be routed.
                    ForEach(groups) { group in
                        Text(group.name.uppercased())
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.models) { model in
                            modelPickerItem(
                                title: model.name,
                                tag: badges[ModelRef(keyID: group.keyID, model: model.name)] ?? model.tag,
                                checked: isSelected(model.name, keyID: group.keyID, in: selection),
                                onRemove: group.keyID.isEmpty ? { removeManualModel(model.name) } : nil) {
                                selectModel(model.name, keyID: group.keyID, capability: capability)
                                modelPickerOpenFor = nil
                            }
                        }
                    }

                    Divider().padding(.vertical, 2)
                    modelPickerItem(title: "Type a model name manually…", muted: true) {
                        modelPickerOpenFor = nil
                        addManualModel(for: capability)
                    }
                    modelPickerItem(title: "Refresh models", systemImage: "arrow.clockwise", muted: true) {
                        Task { await refreshAllKeys() }
                    }
                    modelPickerItem(title: "Manage connections…", systemImage: "slider.horizontal.3",
                                    muted: true) {
                        modelPickerOpenFor = nil
                        showConnections = true
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 300)
    }

    @ViewBuilder
    /// `onRemove` is only passed for hand-typed models: they are the one kind of row the user can take
    /// back out, since a discovered model comes and goes with its connection. The remove button is its
    /// own button beside the row rather than inside it, so a click can't select and delete at once.
    private func modelPickerItem(title: String, tag: String = "", systemImage: String? = nil,
                                 checked: Bool = false, muted: Bool = false,
                                 onRemove: (() -> Void)? = nil,
                                 action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption).foregroundStyle(.tint)
                        .opacity(checked ? 1 : 0)
                        .frame(width: 12)
                    if let systemImage { Image(systemName: systemImage).font(.caption).foregroundStyle(.secondary) }
                    Text(title)
                        .foregroundStyle(muted ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !tag.isEmpty {
                        Text(tag).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.15)))
                    }
                }
                .contentShape(Rectangle())
                .padding(.leading, 10).padding(.trailing, onRemove == nil ? 10 : 4).padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.trailing, 8).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("Remove \(title) from the list")
            }
        }
    }

    private func isSameAsLanguage(_ selection: ModelSelection) -> Bool {
        if case .sameAsLanguage = selection { return true }
        return false
    }

    private func isSelected(_ name: String, keyID: String, in selection: ModelSelection) -> Bool {
        switch selection {
        case .model(let k, let n): return k == keyID && n == name
        case .manual(let n): return keyID.isEmpty && n == name
        default: return false
        }
    }

    private func modelMenuLabel(for capability: ModelCapability) -> String {
        let selection = selectionBinding(capability).wrappedValue
        if isSameAsLanguage(selection) {
            let lang = resolveRegistrySelection(.sameAsLanguage, capability: capability)?.model
            return "Same as language model" + (lang.map { " (\($0))" } ?? "")
        }
        if let resolved = resolveRegistrySelection(selection, capability: capability) {
            return resolved.model
        }
        return draft.registry.entries.isEmpty ? "No connections yet" : "Select a model"
    }

    private func searchBinding(_ capability: ModelCapability) -> Binding<String> {
        Binding(get: { registrySearch[capability] ?? "" },
                set: { registrySearch[capability] = $0 })
    }

    /// Groups for a card, with the cross-group search filter applied.
    private func filteredGroups(for capability: ModelCapability) -> [RegistryModelGroup] {
        let q = (registrySearch[capability] ?? "").lowercased()
        let groups = draft.registry.groups(for: capability)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let matched = group.models.filter { $0.name.lowercased().contains(q) }
            return matched.isEmpty ? nil : RegistryModelGroup(keyID: group.keyID, name: group.name, models: matched)
        }
    }

    private func selectModel(_ name: String, keyID: String, capability: ModelCapability) {
        selectionBinding(capability).wrappedValue = keyID.isEmpty
            ? .manual(name: name)
            : .model(keyID: keyID, name: name)
        if capability == .embedding { refreshEmbeddingStatus() }
    }

    /// Prompt for a hand-typed model name and file it under the "Manually added" group with the
    /// capability the card is filtering for (so it shows up in that card, and any others that match).
    private func addManualModel(for capability: ModelCapability) {
        let alert = NSAlert()
        alert.messageText = "Add a model name"
        alert.informativeText = "Type the exact model id your endpoint expects."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. my-custom-model"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Trailing punctuation is a paste artefact, never part of a model id, and it would be sent
        // to the provider verbatim.
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;."))
        guard !name.isEmpty else { return }
        // Union the card's capability with anything the name signals, so a manual "gpt-4o" also
        // surfaces in the Image card.
        var caps = KeysRegistry.inferCapabilities(forModelID: name)
        caps.insert(capability)
        if let idx = draft.registry.manualModels.firstIndex(where: { $0.name == name }) {
            draft.registry.manualModels[idx].capabilities.formUnion(caps)
        } else {
            draft.registry.manualModels.append(RegistryModel(name: name, tag: "custom", capabilities: caps))
        }
        selectionBinding(capability).wrappedValue = .manual(name: name)
        if capability == .embedding { refreshEmbeddingStatus() }
    }

    /// Take a hand-typed model back out. It is the only removable kind: everything else belongs to a
    /// connection. Any card pointing at it falls back the same way it would if a connection had dropped
    /// the model on a refresh.
    private func removeManualModel(_ name: String) {
        draft.registry.manualModels.removeAll { $0.name == name }
        for capability in ModelCapability.allCases { healSelection(capability) }
        refreshEmbeddingStatus()
    }

    private func refreshAllKeys() async {
        for entry in draft.registry.entries where entry.enabled {
            await discoverModels(forKeyID: entry.id)
        }
        // Fresh lists are fresh evidence: a model benched as withdrawn, or a connection benched for a
        // rejected key, gets another chance (timed cooldowns keep running).
        intelligence.modelHealth.clearRefreshMarks()
    }

    // MARK: Model-aware Test connection

    /// Exactly one state-driven hint for the Language card's OpenAI-compatible provider (reference:
    /// a single line, never stacked).
    private var registryLanguageHint: String {
        if draft.registry.entries.isEmpty {
            return "Add a connection to get started."
        }
        if resolveRegistrySelection(draft.langSelection, capability: .language) == nil {
            return "Pick a model to get started."
        }
        return "Each model routes to the connection that serves it."
    }

    // MARK: - MLX download

    /// Download / progress on its own row (keeps the Model Picker clean). Nothing shows once the
    /// selected model is downloaded — it then lives in the "Downloaded models" list with Remove.
    @ViewBuilder
    private var mlxDownloadRow: some View {
        if mlxDownload == .downloading {
            SettingsRow("Download",
                        caption: mlxStalled ? "Slow or stalled. Cancel and retry if needed." : nil) {
                HStack(spacing: 8) {
                    if let total = mlxRemoteSize, total > 0 {
                        ProgressView(value: mlxProgress).frame(width: 120)
                        Text("\(Int(mlxProgress * 100))% · \(byteString(mlxDownloadedBytes)) / \(byteString(total))")
                            .font(SettingsFont.sub).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(SettingsFont.sub).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { cancelMLXDownload() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else if case .failed(let message) = mlxDownload {
            SettingsRow("Download", caption: message) {
                Button { downloadMLXModel() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            }
        } else if !MLXProvider.isDownloaded(draft.mlxModel) {
            SettingsRow("Download",
                        caption: draft.localOnly ? "Local-only mode blocks downloads." : nil) {
                Button { downloadMLXModel() } label: {
                    Label(mlxDownloadLabel, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(draft.localOnly)
            }
        } else if let entry = currentModelEntry {
            SettingsRow("Downloaded", caption: "\(byteString(entry.sizeBytes)) on this Mac.") {
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    }
                    .buttonStyle(.bordered)
                    Button("Remove") { mlxRemoveConfirm = true }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .confirmationDialog("Remove \(entry.repoID)?",
                                            isPresented: $mlxRemoveConfirm, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) { removeMLXModel(entry) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes the downloaded files (\(byteString(entry.sizeBytes))). "
                                + "You can download it again later.")
                        }
                }
            }
        }
    }

    private var currentModelEntry: MLXCache.Entry? {
        mlxInstalled.first { MLXProvider.normalizedID($0.repoID) == MLXProvider.normalizedID(draft.mlxModel) }
    }

    /// Download button label with the size shown directly (no hover needed).
    private var mlxDownloadLabel: String {
        if mlxSizeLoading { return "Download model · checking size…" }
        if let size = mlxRemoteSize { return "Download model · \(byteString(size))" }
        return "Download model"
    }

    private func downloadMLXModel() {
        let id = draft.mlxModel
        mlxDownload = .downloading
        mlxProgress = 0
        mlxDownloadedBytes = 0
        mlxStalled = false
        mlxLastProgressAt = Date()
        let total = mlxRemoteSize

        // Watchdog: flag a possible stall if the loader reports no progress for a while.
        mlxPollTask?.cancel()
        mlxPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if mlxDownload == .downloading, Date().timeIntervalSince(mlxLastProgressAt) > 30 {
                    mlxStalled = true
                }
            }
        }

        mlxDownloadTask?.cancel()
        mlxDownloadTask = Task {
            do {
                // Real loader progress (fraction of bytes received).
                try await MLXProvider.ensureDownloaded(id) { frac in
                    Task { @MainActor in
                        mlxProgress = frac
                        if let total { mlxDownloadedBytes = Int64(frac * Double(total)) }
                        mlxLastProgressAt = Date()
                        mlxStalled = false
                    }
                }
                if Task.isCancelled { return }
                mlxProgress = 1
                mlxDownload = .ready
            } catch {
                // A cancel leaves us in .idle already; only surface genuine failures.
                if !Task.isCancelled, !(error is CancellationError) {
                    mlxDownload = .failed(error.localizedDescription)
                }
            }
            mlxPollTask?.cancel()
            refreshMLXInstalled()
        }
    }

    private func cancelMLXDownload() {
        mlxDownloadTask?.cancel()
        mlxPollTask?.cancel()
        mlxDownload = .idle
        mlxProgress = 0
        mlxDownloadedBytes = 0
        mlxStalled = false
        refreshMLXInstalled()
    }

    private func refreshMLXInstalled() {
        mlxInstalled = MLXCache.installed()
    }

    /// Look up the model's download size from Hugging Face (debounced; skipped in Local-only mode or
    /// when it's already downloaded) so the user sees the size before committing.
    private func refreshMLXRemoteSize() {
        mlxSizeTask?.cancel()
        mlxRemoteSize = nil
        mlxSizeLoading = false
        let id = draft.mlxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.localOnly, !id.isEmpty, !MLXProvider.isDownloaded(id) else { return }
        mlxSizeLoading = true
        mlxSizeTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let size = await MLXCache.remoteSizeBytes(for: id)
            if Task.isCancelled { return }
            mlxRemoteSize = size
            mlxSizeLoading = false
        }
    }

    private func removeMLXModel(_ entry: MLXCache.Entry) {
        Task {
            try? await MLXProvider.remove(entry)
            if MLXProvider.normalizedID(draft.mlxModel) == MLXProvider.normalizedID(entry.repoID) {
                mlxDownload = .idle
            }
            refreshMLXInstalled()
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Curated mlx-community text models (4-bit, small→larger) for the Suggested menu. You can still
    /// paste any MLX text model id from huggingface.co/models?library=mlx into the field.
    /// The Text engine menu offers text models **and** VL models — a VLM also generates text, so it
    /// can serve both roles (one model for text + Identify).
    static var mlxTextSuggestions: [(name: String, id: String)] { mlxSuggestions + mlxVisionSuggestions }
    private static var mlxSuggestionIDs: Set<String> { Set(mlxTextSuggestions.map(\.id)) }

    private var mlxIsCustom: Bool { !Self.mlxSuggestionIDs.contains(draft.mlxModel) }

    // Suggestions split by state (preserves original order within each group).
    private var mlxDownloadedSuggestions: [(name: String, id: String)] {
        Self.mlxTextSuggestions.filter { MLXProvider.isDownloaded($0.id) }
    }
    private var mlxAvailableSuggestions: [(name: String, id: String)] {
        Self.mlxTextSuggestions.filter { !MLXProvider.isDownloaded($0.id) }
    }

    @ViewBuilder
    private func mlxMenuItem(_ suggestion: (name: String, id: String)) -> some View {
        Button { draft.mlxModel = suggestion.id } label: {
            Label(suggestion.name,
                  systemImage: MLXProvider.isDownloaded(suggestion.id)
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
    }

    /// The menu's label: the selected suggestion's name, or the custom id (or "Custom…" when empty).
    private var mlxMenuLabel: String {
        if let suggestion = Self.mlxTextSuggestions.first(where: { $0.id == draft.mlxModel }) {
            return suggestion.name
        }
        return draft.mlxModel.isEmpty ? "Custom…" : draft.mlxModel
    }

    private static let mlxSuggestions: [(name: String, id: String)] = [
        ("Qwen3 0.6B · 4-bit — tiny & fast", "mlx-community/Qwen3-0.6B-4bit"),
        ("Llama 3.2 1B · 4-bit", "mlx-community/Llama-3.2-1B-Instruct-4bit"),
        ("Llama 3.2 3B · 4-bit", "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        ("Qwen2.5 3B · 4-bit", "mlx-community/Qwen2.5-3B-Instruct-4bit"),
        ("Phi-3.5 mini · 4-bit", "mlx-community/Phi-3.5-mini-instruct-4bit"),
        ("Gemma 2 2B · 4-bit", "mlx-community/gemma-2-2b-it-4bit"),
        ("Qwen2.5 7B · 4-bit", "mlx-community/Qwen2.5-7B-Instruct-4bit"),
        ("Mistral 7B v0.3 · 4-bit", "mlx-community/Mistral-7B-Instruct-v0.3-4bit"),
    ]

    /// Curated mlx-community vision-language (VLM) models for the Image role.
    static let mlxVisionSuggestions: [(name: String, id: String)] = [
        ("Qwen2-VL 2B · 4-bit — small", "mlx-community/Qwen2-VL-2B-Instruct-4bit"),
        ("Qwen2.5-VL 3B · 4-bit", "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"),
        ("Qwen2.5-VL 7B · 4-bit", "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"),
    ]

    /// Context-window control for the selected OpenAI-compatible language model: Auto (detect from
    /// /v1/models, else infer from the model name) or a manual token count — for a gateway that doesn't
    /// advertise its window. Bound to `draft.langContext` (a single override for the active selection).
    @ViewBuilder private func registryContextControl() -> some View {
        let value = draft.langContext
        let manual = value > 0
        let model = resolveRegistrySelection(draft.langSelection, capability: .language)?.model ?? ""
        let autoTokens = intelligence.cloudContextTokens
            ?? IntelligenceCoordinator.inferContextFromModelName(model) ?? 32_000

        SettingsRow("Context window",
                    caption: manual
                        ? "Manual override. Up to ~128k tokens of history and sources per chat."
                        : "Auto · \(autoTokens.formatted()) tokens detected") {
            SettingsSwitch(
                title: "Set manually",
                isOn: Binding(
                    get: { manual },
                    set: { on in
                        draft.langContext = on
                            ? (IntelligenceCoordinator.inferContextFromModelName(model) ?? 200_000) : 0
                    }),
                info: "Detected from your endpoint or inferred from the model name. Turn this on "
                    + "if your gateway serves a big-context model but doesn't report it.")
        }

        if manual {
            SettingsRow("Tokens") {
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { draft.langContext },
                                                 set: { draft.langContext = max(0, $0) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    ForEach([128_000, 200_000, 1_000_000], id: \.self) { preset in
                        Button(Self.presetLabel(preset)) { draft.langContext = preset }
                            .buttonStyle(.bordered)
                            .tint(value == preset ? Color.accentColor : nil)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private static func presetLabel(_ n: Int) -> String {
        switch n {
        case 1_000_000: return "1M"
        case 200_000:   return "200k"
        case 128_000:   return "128k"
        default:        return n.formatted()
        }
    }

    private var privacyLine: String {
        if draft.localOnly, !draft.provider.isLocalKind {
            let service = serviceName(resolvedLanguageBaseURL)
            if service == Self.unrecognizedServiceName {
                return "Local-only is on, but the base URL doesn't look valid — check it in Settings."
            }
            return "Local-only is on, but \(service) is a cloud model — your "
                + "selection still goes to that endpoint. Use Apple or Ollama for full isolation."
        }
        switch draft.provider {
        case .onDevice, .ollama, .mlx:
            return "Runs on this Mac — nothing leaves your device."
        case .openAICompatible:
            // Privacy depends on the key that backs the *selected* language model, not one global URL.
            guard let resolved = resolveRegistrySelection(draft.langSelection, capability: .language) else {
                return "No model selected yet — pick one under Language model."
            }
            guard let entry = resolved.key else {
                return "“\(resolved.model)” is a manually-added model with no registered key — register a key for it before use."
            }
            if entry.isLocal { return "Local server (“\(entry.name)”) — stays on this Mac." }
            let service = serviceName(entry.baseURL)
            if service == Self.unrecognizedServiceName {
                return "“\(entry.name)” base URL doesn't look valid — check it before this model can be used."
            }
            return "Cloud — your selection is sent to \(service) via “\(entry.name)”. Use a multimodal model for image questions."
        case .anthropic:
            return "Cloud — your selection is sent to Anthropic. A vision Claude model also handles images."
        }
    }

    /// Sentinel returned by `serviceName` when the URL couldn't be parsed at all — kept distinct from
    /// "the provider" (a genuine, just-unrecognized cloud host) so callers never mistake "couldn't
    /// parse" for "cloud".
    private static let unrecognizedServiceName = "an unrecognized address"

    private func serviceName(_ urlString: String) -> String {
        guard let host = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              !host.isEmpty else { return Self.unrecognizedServiceName }
        if host.contains("googleapis") { return "Google" }
        if host.contains("groq") { return "Groq" }
        if host.contains("openrouter") { return "OpenRouter" }
        if host.contains("openai") { return "OpenAI" }
        if isLocalHost(host) { return "a local server" }
        return "the provider"
    }

    /// True for loopback hosts — mirrors `OpenAICompatibleProvider.isLocal`, used both by the privacy
    /// label above and by the API-key caption/reload-message below so "local" means the same thing
    /// everywhere in Settings.
    private func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Whether a (possibly untrimmed) base URL string resolves to a local host.
    private func isLocalBaseURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return false }
        return isLocalHost(host)
    }

    private var noModels: Bool { modelsLoaded && availableModels.isEmpty }

    /// Dropdown of installed Ollama models, with the "auto" choice + a "(not installed)" fallback
    /// for a saved name that's no longer present.
    @ViewBuilder
    private func ollamaModelControl(selection: Binding<String>, autoLabel: String = "Auto") -> some View {
        HStack(spacing: 8) {
            if noModels {
                Text("No Ollama models")
                    .font(SettingsFont.label).foregroundStyle(.secondary)
            } else {
                Picker("", selection: selection) {
                    Text(autoLabel).tag("")
                    let current = selection.wrappedValue
                    if !current.isEmpty, !availableModels.contains(current) {
                        Text("\(current) (not installed)").tag(current)
                    }
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            refreshModelsButton
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - About

    private var about: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "lasso")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Lasso").font(.title.bold())
                Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Text("On-device screen intelligence for Apple Silicon.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(intelligence.privacyNote,
                  systemImage: intelligence.usedOffDeviceThisSession ? "cloud" : "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 0)
            Text("Runs locally by default · your keys stay in the Keychain")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    // MARK: - Load / Apply

    private func load() async {
        availableModels = await OllamaModels.installed()
        modelsLoaded = true
        // Clean-break migration off the old per-service scheme (one-time; purges old keys, arms the
        // notice). Must run before we read the registry so the version flag is set.
        KeysRegistry.migrateIfNeeded()
        if UserDefaults.standard.bool(forKey: KeysRegistry.noticeKey) {
            UserDefaults.standard.set(false, forKey: KeysRegistry.noticeKey)
            showMigrationNotice = true
        }
        var d = Draft()
        d.provider = intelligence.preferred
        d.ollamaModel = intelligence.ollamaModel
        d.ollamaBaseURL = OllamaEndpoint.customURLString
        d.ollamaAutoStart = UserDefaults.standard.bool(forKey: "ollama.autoStart")
        d.mlxModel = intelligence.mlxModel
        d.visionModel = intelligence.visionModel
        d.visionMLXModel = intelligence.visionMLXModel
        d.anthropicBaseURL = intelligence.anthropicBaseURL
        d.anthropicModel = intelligence.anthropicModel
        d.anthropicKey = Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? ""
        d.visionEngine = intelligence.visionEngine
        d.visionAnthropicBaseURL = intelligence.visionAnthropicBaseURL
        d.visionAnthropicModel = intelligence.visionAnthropicModel
        d.visionAnthropicKey = Keychain.get("vision.anthropic.apiKey") ?? ""

        // OpenAI-compatible omni-router: the shared connection registry (JSON) + each section's saved
        // selection. `KeysRegistry.load()` heals any connection the old UI had switched off, and
        // persists that — healing only the draft here would have made the panel disagree with every
        // other reader (the chat switcher saw one connection while Settings claimed three).
        d.registry = KeysRegistry.load()
        d.langSelection = loadSelection("intelligence.keys.selection.language") ?? .none
        d.visionSelection = loadSelection("intelligence.keys.selection.vision") ?? .none
        d.embeddingSelection = loadSelection("intelligence.keys.selection.embedding") ?? .none
        d.langContext = UserDefaults.standard.integer(forKey: "intelligence.keys.language.context")
        d.autoFallback = intelligence.autoFallbackEnabled
        d.fallbackRaceAfter = intelligence.fallbackRaceAfterSeconds
        // Seed the in-memory key values from the Keychain (Draft never carries secrets).
        var keyVals: [String: String] = [:]
        for entry in d.registry.entries {
            keyVals[entry.id] = Keychain.get(entry.keychainAccount) ?? ""
        }

        for connector in Connectors.all {
            d.connectorEnabled[connector.id] = connector.isEnabled
            if connector.keyAccount != nil { d.connectorKeys[connector.id] = connector.key() }
        }
        d.localOnly = UserDefaults.standard.bool(forKey: "privacy.localOnly")
        d.lensSearch = UserDefaults.standard.bool(forKey: LensSearchAction.enabledKey)
        d.pretranslate = UserDefaults.standard.object(forKey: "translation.pretranslate") as? Bool ?? true
        d.launchAtLogin = LoginItem.isEnabled
        d.actionBarStyle = UserDefaults.standard.string(forKey: Self.actionBarStyleKey)
            ?? ActionBarStyle.compact.rawValue
        d.hideUnavailable = UserDefaults.standard.bool(forKey: Self.hideUnavailableKey)
        d.colorfulActions = UserDefaults.standard.bool(forKey: Self.colorfulKey)
        d.embeddingProvider = intelligence.embeddingProvider
        d.embeddingOllamaModel = intelligence.embeddingOllamaModel
        d.embeddingMLXModel = intelligence.embeddingMLXModel
        // Heal an inconsistent saved state (local-only + a cloud engine / cloud image provider).
        if d.localOnly, !d.provider.isLocalKind { d.provider = .onDevice }
        if d.localOnly, d.visionEngine == .openAICompatible || d.visionEngine == .anthropic {
            d.visionEngine = .ollama
        }
        if d.localOnly, !d.embeddingProvider.isLocalKind { d.embeddingProvider = .automatic }
        draft = d
        saved = d
        registryKeyValues = keyVals
        savedRegistryKeyValues = keyVals
        await loadCloudModels()
        await loadVisionModels()
        // Re-discover each enabled key's models so the merged list is fresh on open. This mutates
        // draft.registry.*.models, which is a load-time refresh, not a user edit — re-baseline `saved`
        // so it doesn't spuriously read as "Unsaved changes".
        await refreshAllKeys()
        // Collapse a legacy `.sameAsLanguage` model selection into a concrete one. Following the
        // Language model is now the Image section's Inherit switch (visionEngine == .matchText), so
        // keeping the same intent in a second place is exactly the duplication this redesign removes.
        if draft.visionSelection == .sameAsLanguage {
            draft.visionSelection = concreteCopy(of: .sameAsLanguage)
        }
        if draft.embeddingSelection == .sameAsLanguage {
            draft.embeddingSelection = concreteCopy(of: .sameAsLanguage)
        }
        // Discovery may also heal dangling selections (a saved model no longer exposed). Both are
        // load-time corrections, not user edits — re-baseline the registry + selections.
        saved.registry = draft.registry
        saved.langSelection = draft.langSelection
        saved.visionSelection = draft.visionSelection
        saved.embeddingSelection = draft.embeddingSelection
    }

    /// Decode a persisted `ModelSelection` (stored as a compact string form).
    private func loadSelection(_ defaultsKey: String) -> ModelSelection? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        if raw == "none" { return ModelSelection.none }
        if raw == "sameAsLanguage" { return .sameAsLanguage }
        if let rest = raw.dropPrefixIfPresent("manual:") { return .manual(name: String(rest)) }
        if let rest = raw.dropPrefixIfPresent("model:") {
            // "model:<keyID>\t<name>"
            let parts = rest.components(separatedBy: "\t")
            if parts.count == 2 { return .model(keyID: parts[0], name: parts[1]) }
        }
        return nil
    }

    private func encodeSelection(_ selection: ModelSelection) -> String {
        switch selection {
        case .none: return "none"
        case .sameAsLanguage: return "sameAsLanguage"
        case .manual(let name): return "manual:\(name)"
        case .model(let keyID, let name): return "model:\(keyID)\t\(name)"
        }
    }

    private func apply() {
        // Local-only must mean local: a cloud engine / cloud image provider is committed as local.
        if draft.localOnly, !draft.provider.isLocalKind { draft.provider = .onDevice }
        if draft.localOnly, draft.visionEngine == .openAICompatible || draft.visionEngine == .anthropic {
            draft.visionEngine = .ollama
        }
        if draft.localOnly, !draft.embeddingProvider.isLocalKind { draft.embeddingProvider = .automatic }
        intelligence.preferred = draft.provider
        intelligence.ollamaModel = draft.ollamaModel
        intelligence.mlxModel = draft.mlxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        OllamaEndpoint.customURLString = draft.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(draft.ollamaAutoStart, forKey: "ollama.autoStart")
        Task { await OllamaEndpoint.autodetect() }   // re-resolve the effective server after a change
        intelligence.visionModel = draft.visionModel
        intelligence.visionMLXModel = draft.visionMLXModel.trimmingCharacters(in: .whitespacesAndNewlines)
        intelligence.anthropicBaseURL = draft.anthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        intelligence.anthropicModel = draft.anthropicModel
        Keychain.set(draft.anthropicKey, for: "anthropic.apiKey")
        intelligence.visionEngine = draft.visionEngine
        intelligence.visionAnthropicBaseURL = draft.visionAnthropicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        intelligence.visionAnthropicModel = draft.visionAnthropicModel
        Keychain.set(draft.visionAnthropicKey, for: "vision.anthropic.apiKey")

        // OpenAI-compatible omni-router: persist the shared registry (JSON) + each key's secret, and
        // each card's selection. Then commit the effective per-role config the coordinator consumes,
        // resolving each card's selection to its backing key (URL + model + key).
        draft.registry.save()
        for entry in draft.registry.entries {
            Keychain.set(registryKeyValues[entry.id] ?? "", for: entry.keychainAccount)
        }
        UserDefaults.standard.set(encodeSelection(draft.langSelection), forKey: "intelligence.keys.selection.language")
        UserDefaults.standard.set(encodeSelection(draft.visionSelection), forKey: "intelligence.keys.selection.vision")
        UserDefaults.standard.set(encodeSelection(draft.embeddingSelection), forKey: "intelligence.keys.selection.embedding")
        UserDefaults.standard.set(draft.langContext, forKey: "intelligence.keys.language.context")
        intelligence.autoFallbackEnabled = draft.autoFallback
        intelligence.fallbackRaceAfterSeconds = draft.fallbackRaceAfter

        // Effective language config → the single endpoint the coordinator drives. A hand-typed model
        // has no connection of its own: it rides on whichever endpoint is already configured, exactly
        // as the chat switcher's "Manually added" group does. Requiring a connection here meant Save &
        // Apply stored the choice and then kept sending requests to the previous model.
        if let lang = resolveRegistrySelection(draft.langSelection, capability: .language) {
            intelligence.openAIModel = lang.model
            if let key = lang.key {
                intelligence.openAIBaseURL = key.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                // The connection's protocol travels with the flattened config, because that's what
                // decides which transport `buildProvider()` constructs.
                intelligence.openAIConnectionKind = key.kind
                Keychain.set(registryKeyValues[key.id] ?? "", for: "openai.apiKey")
            }
        }
        // Effective image config (resolving "same as language" against the language selection).
        if let vis = resolveRegistrySelection(draft.visionSelection, capability: .vision) {
            intelligence.visionOpenAIModel = vis.model
            if let key = vis.key {
                intelligence.visionOpenAIBaseURL = key.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                intelligence.visionOpenAIConnectionKind = key.kind
                Keychain.set(registryKeyValues[key.id] ?? "", for: "vision.openai.apiKey")
            }
        }

        for connector in Connectors.all {
            UserDefaults.standard.set(draft.connectorEnabled[connector.id] ?? connector.defaultEnabled,
                                      forKey: connector.enabledKey)
            if let account = connector.keyAccount {
                Keychain.set(draft.connectorKeys[connector.id] ?? "", for: account)
            }
        }
        UserDefaults.standard.set(draft.localOnly, forKey: "privacy.localOnly")
        UserDefaults.standard.set(draft.lensSearch, forKey: LensSearchAction.enabledKey)
        UserDefaults.standard.set(draft.pretranslate, forKey: "translation.pretranslate")
        UserDefaults.standard.set(draft.actionBarStyle, forKey: Self.actionBarStyleKey)
        UserDefaults.standard.set(draft.hideUnavailable, forKey: Self.hideUnavailableKey)
        UserDefaults.standard.set(draft.colorfulActions, forKey: Self.colorfulKey)
        if draft.launchAtLogin != saved.launchAtLogin { LoginItem.set(draft.launchAtLogin) }
        // Embedding backend — commit, then reset chat indexes if the backend actually changed (vectors
        // from a different embedder are incomparable, so the in-RAM indexes must rebuild).
        let embeddingChanged = draft.embeddingProvider != saved.embeddingProvider
            || draft.embeddingOllamaModel != saved.embeddingOllamaModel
            || draft.embeddingMLXModel != saved.embeddingMLXModel
            || (draft.embeddingProvider == .openAICompatible
                && (draft.embeddingSelection != saved.embeddingSelection
                    || draft.registry != saved.registry
                    || registryKeyValues != savedRegistryKeyValues))
        intelligence.embeddingProvider = draft.embeddingProvider
        intelligence.embeddingOllamaModel = draft.embeddingOllamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        intelligence.embeddingMLXModel = draft.embeddingMLXModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Effective embedding config (its own endpoint, resolved from the shared registry).
        if let emb = resolveRegistrySelection(draft.embeddingSelection, capability: .embedding) {
            intelligence.embeddingOpenAIModel = emb.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = emb.key {
                intelligence.embeddingOpenAIBaseURL = key.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                intelligence.embeddingOpenAIConnectionKind = key.kind
                Keychain.set(registryKeyValues[key.id] ?? "", for: "embedding.openai.apiKey")
            }
        }
        if embeddingChanged { ChatController.shared.embeddingConfigChanged() }
        Task { await intelligence.refreshVisionAvailability() }   // re-grey vision features as needed
        saved = draft
        savedRegistryKeyValues = registryKeyValues
    }
}

/// The real brand logo for a connector, fetched from the favicon service (credits the service and
/// looks professional). Falls back to the SF Symbol when offline, in local-only mode, or while
/// loading.
private struct BrandIcon: View {
    let domain: String?
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let domain, !PrivacyMode.localOnly {
                AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var fallback: some View {
        Image(systemName: fallbackSymbol).foregroundStyle(.tint)
    }
}

/// One connector in the store: an expandable row with a status chip, an enable toggle, an inline
/// setup guide (numbered steps + "Open" links), a key field, and a Test button. Driven entirely by
/// the `Connector` descriptor, so the card is generic across every integration.
private struct ConnectorCard: View {
    let connector: Connector
    @Binding var enabled: Bool
    @Binding var key: String
    let localOnly: Bool

    @Environment(\.openURL) private var openURL
    @State private var expanded = false
    @State private var test: ConnectionTest.Outcome = .idle

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(connector.summary).font(.caption).foregroundStyle(.secondary)
                guide
                if connector.requiresKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API key").font(.caption).foregroundStyle(.secondary)
                        SecureKeyField("Paste your key", text: $key)
                    }
                }
                if let usage { Text(usage).font(.caption2).foregroundStyle(.tertiary) }
                testRow
            }
            .padding(.top, 4)
        } label: {
            header
        }
        .disclosureGroupStyle(.automatic)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandIcon(domain: connector.iconDomain, fallbackSymbol: connector.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                statusChip
            }
            Spacer()
            Toggle("", isOn: $enabled).labelsHidden().disabled(localOnly)
        }
    }

    private var statusChip: some View {
        let (text, color) = status
        return Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
    }

    /// (label, colour) for the chip, reflecting local-only, test result, then config state.
    private var status: (String, Color) {
        if localOnly { return ("Paused · local-only", .secondary) }
        switch test {
        case .ok: return ("Connected", .green)
        case .failure: return ("Error", .orange)
        default: break
        }
        if !enabled { return ("Off", .secondary) }
        if connector.requiresKey, key.isEmpty { return ("Needs key", .orange) }
        return connector.requiresKey ? ("Ready", .blue) : ("On", .blue)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(connector.guide.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(step.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if let link = step.link {
                        Spacer(minLength: 4)
                        Button(step.linkLabel ?? "Open") { openURL(link) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            if let note = connector.guide.note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var testRow: some View {
        HStack(spacing: 8) {
            Button("Test") { runTest() }
                .buttonStyle(.bordered)
                // No network in local-only mode — connectors are paused, so don't let Test reach out.
                .disabled(test == .testing || localOnly || (connector.requiresKey && key.isEmpty))
            Spacer()
            switch test {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").font(.caption).foregroundStyle(.secondary)
                }
            case .ok(let ms):
                Label("Connected · \(ms) ms", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
            }
        }
    }

    /// Monthly usage line for the budgeted search APIs.
    private var usage: String? {
        let source: String
        switch connector.id {
        case "tavily": source = "tavily"
        case "serpApi": source = "serpapi"
        default: return nil
        }
        guard !key.isEmpty else { return nil }
        let cap = SearchQuota.caps[source]?.monthly ?? 0
        return "This month — \(SearchQuota.usedMonth(source))/\(cap) used"
    }

    private func runTest() {
        test = .testing
        let connector = connector
        let key = key
        Task { test = await connector.test(key) }
    }
}

/// Validates a provider's staged config with a lightweight call, so Settings can show ✓/✗ before
/// the user saves. Reuses each provider's real endpoints/URL builders.
enum ConnectionTest {
    enum Outcome: Equatable {
        case idle, testing
        case ok(Int)            // latency in ms
        case failure(String)
    }

    static func run(provider: ProviderKind,
                    openAIBaseURL: String, openAIKey: String, openAIModel: String,
                    anthropicBaseURL: String, anthropicKey: String, anthropicModel: String) async -> Outcome {
        let start = Date()
        func ms() -> Int { max(1, Int(Date().timeIntervalSince(start) * 1000)) }

        switch provider {
        case .onDevice:
            return await OnDeviceProvider().checkAvailability()
                ? .ok(ms())
                : .failure("Apple Intelligence isn't available on this Mac.")

        case .ollama:
            let models = await OllamaModels.installed()
            if !models.isEmpty { return .ok(ms()) }
            let up = await OllamaProvider().checkAvailability()
            let host = OllamaEndpoint.baseURL.host ?? "localhost"
            let port = OllamaEndpoint.baseURL.port.map { ":\($0)" } ?? ""
            return up
                ? .failure("Ollama is running but has no models. Try `ollama pull qwen3:4b`.")
                : .failure("Can't reach Ollama at \(host)\(port). Is the Ollama app running?")

        case .mlx:
            return await MLXProvider().checkAvailability()
                ? .ok(ms())
                : .failure("MLX runtime is wired, but the model adapter is still experimental.")

        case .openAICompatible:
            return await testOpenAI(base: openAIBaseURL, key: openAIKey, model: openAIModel, ms: ms)

        case .anthropic:
            return await testAnthropic(base: anthropicBaseURL, key: anthropicKey, model: anthropicModel, ms: ms)
        }
    }

    private static func testOpenAI(base: String, key: String, model: String, ms: () -> Int) async -> Outcome {
        guard let baseURL = URL(string: base), baseURL.host != nil else { return .failure("Invalid base URL.") }
        var trimmed = baseURL.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/models") else { return .failure("Invalid base URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach \(url.host ?? base).")
        }
        guard http.statusCode == 200 else {
            return .failure("HTTP \(http.statusCode) — " + OpenAICompatibleProvider.hint(for: http.statusCode))
        }
        return model.isEmpty ? .failure("Connected, but no model name is set.") : .ok(ms())
    }

    private static func testAnthropic(base: String, key: String, model: String, ms: () -> Int) async -> Outcome {
        guard !key.isEmpty else { return .failure("Enter an API key.") }
        guard !model.isEmpty else { return .failure("Enter a model name.") }
        guard let baseURL = URL(string: base), baseURL.host != nil else { return .failure("Invalid base URL.") }
        var request = URLRequest(url: AnthropicProvider.messagesURL(base: baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1, "messages": [["role": "user", "content": "ping"]],
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach Anthropic.")
        }
        switch http.statusCode {
        case 200: return .ok(ms())
        case 401, 403: return .failure("Check the API key.")
        case 404: return .failure("Model not found — check the model name.")
        default: return .failure("HTTP \(http.statusCode) — check the model name and key.")
        }
    }
}
