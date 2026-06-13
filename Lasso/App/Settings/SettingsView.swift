import SwiftUI
import KeyboardShortcuts

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
        // OpenAI-compatible. The API *key* is shared per service (it's the account key, not per role),
        // so Text and Image reuse it for the same service. The *model* is per role + service. Each
        // service (OpenAI/Groq/OpenRouter/Custom) keeps its own key + model; switching Service swaps.
        var openAIService = "openai"
        var openAICustomBaseURL = "https://api.openai.com/v1"
        var openAIKeyByService: [String: String] = [:]      // shared by Text + Image, keyed by service
        var openAIModelByService: [String: String] = [:]    // Text models, per service
        var anthropicBaseURL = "https://api.anthropic.com"
        var anthropicModel = "claude-3-5-haiku-latest"
        var anthropicKey = ""
        // Independent image (vision) provider.
        var visionEngine: VisionEngine = .matchText
        var visionOpenAIService = "openai"
        var visionOpenAICustomBaseURL = "https://api.openai.com/v1"
        var visionOpenAIModelByService: [String: String] = [:]   // Image models, per service
        var visionAnthropicBaseURL = "https://api.anthropic.com"
        var visionAnthropicModel = "claude-3-5-sonnet-latest"
        var visionAnthropicKey = ""

        // Active-service convenience, computed from the per-service dicts (consumed by serviceName,
        // privacyLine, loadCloudModels, ConnectionTest, hints).
        var openAIBaseURL: String { SettingsView.openAIServiceURL(openAIService, custom: openAICustomBaseURL) }
        var openAIKey: String { openAIKeyByService[openAIService] ?? "" }
        var openAIModel: String { openAIModelByService[openAIService] ?? "" }
        var visionOpenAIBaseURL: String { SettingsView.openAIServiceURL(visionOpenAIService, custom: visionOpenAICustomBaseURL) }
        var visionOpenAIKey: String { openAIKeyByService[visionOpenAIService] ?? "" }   // shared key
        var visionOpenAIModel: String { visionOpenAIModelByService[visionOpenAIService] ?? "" }
        // Connector enable + key state, keyed by Connector.id — the catalog is the single source of
        // truth, so adding a connector needs no new Draft fields.
        var connectorEnabled: [String: Bool] = [:]
        var connectorKeys: [String: String] = [:]
        var localOnly = false
        var pretranslate = true
        var launchAtLogin = false
    }

    private enum Tab: Hashable { case general, intelligence, connectors, about }

    @State private var tab: Tab = .general
    @State private var draft = Draft()
    @State private var saved = Draft()
    @State private var availableModels: [String] = []
    @State private var modelsLoaded = false
    @State private var testState: ConnectionTest.Outcome = .idle

    // Fetched cloud model catalogs (OpenAI-compatible / Anthropic), like the Ollama model list.
    @State private var openAIModels: [String] = []
    @State private var anthropicModels: [String] = []
    @State private var visionOpenAIModels: [String] = []
    @State private var visionAnthropicModels: [String] = []
    @State private var loadingModels = false
    @State private var modelLoadNote: String?
    @State private var ollamaStatus: OllamaEndpoint.Status?
    @State private var mlxDownload: MLXDownloadState = .idle
    @State private var mlxInstalled: [MLXCache.Entry] = []
    @State private var mlxRemoteSize: Int64?
    @State private var mlxSizeLoading = false
    @State private var mlxSizeTask: Task<Void, Never>?
    @State private var mlxProgress: Double = 0          // 0–1, when the total size is known
    @State private var mlxDownloadedBytes: Int64 = 0

    enum MLXDownloadState: Equatable { case idle, downloading, ready, failed(String) }
    @AppStorage("ui.actionBarStyle") private var actionBarStyle = ActionBarStyle.compact.rawValue
    @AppStorage("ui.actionBarHideUnavailable") private var hideUnavailable = false

    private var isDirty: Bool { draft != saved }

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
                Button("Revert") { draft = saved }
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
                Toggle("Launch at login", isOn: $draft.launchAtLogin)
            }
            Section("Appearance") {
                Picker("Action bar", selection: $actionBarStyle) {
                    ForEach(ActionBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                caption("Compact: icons only · Cozy: icons with names.")
                Toggle("Auto-hide unavailable actions", isOn: $hideUnavailable)
                caption("Off: greyed out in place.")
            }
            Section("Privacy") {
                Toggle("Local-only mode", isOn: $draft.localOnly)
                caption("Blocks all network calls except your chosen model. Best for work Macs.")
            }
            Section("Translation") {
                Toggle("Pre-translate selections", isOn: $draft.pretranslate)
                caption("Translates in the background so Translate is instant.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Intelligence

    private var intelligenceTab: some View {
        Form {
            Section("Text") {
                Picker("Engine", selection: $draft.provider) {
                    ForEach(availableProviders) { Text($0.label).tag($0) }
                }
                providerConfig
                connectionRow
                caption(privacyLine)
            }

            Section("Image (Identify)") {
                Picker("Provider", selection: $draft.visionEngine) {
                    ForEach(availableVisionEngines) { Text($0.label).tag($0) }
                }
                visionProviderConfig
                caption(imageModelHint)
            }

            // Ollama plumbing shown once, only when text OR image actually uses Ollama.
            if usesOllama {
                Section("Ollama") {
                    TextField("Server", text: $draft.ollamaBaseURL, prompt: Text("Auto — localhost:11434"))
                        .onChange(of: draft.ollamaBaseURL) { _, _ in scheduleOllamaStatus() }
                    ollamaStatusCaption
                    if OllamaLauncher.isInstalled {
                        Toggle("Start Ollama automatically when Lasso launches", isOn: $draft.ollamaAutoStart)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Populate the cloud catalogs when switching to a cloud engine (Ollama loads in `load()`).
        .onChange(of: draft.provider) { _, _ in Task { await loadCloudModels() } }
        .onChange(of: draft.visionEngine) { _, _ in Task { await loadVisionModels() } }
        .task { scheduleOllamaStatus(); await loadVisionModels() }
    }

    /// Image providers offered — cloud hidden in local-only mode (keyed to the saved setting, like the
    /// text engine list, so it only changes after Save & Apply).
    private var availableVisionEngines: [VisionEngine] {
        saved.localOnly ? [.matchText, .ollama] : VisionEngine.allCases
    }

    /// Whether the Ollama config block is relevant: either role uses Ollama, or Apple text falls back
    /// to local Ollama for images.
    private var usesOllama: Bool {
        draft.provider == .ollama || draft.visionEngine == .ollama
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
                connectorList(Connectors.all.filter { $0.usesImage })
            } header: {
                Text("Looks at the image")
            } footer: {
                caption("Reverse-image search — identifies what's actually in the picture.")
            }

            Section {
                connectorList(Connectors.all.filter { !$0.usesImage })
            } header: {
                Text("Adds web context (text search)")
            } footer: {
                caption("These search the web by text — built from what the vision model reads in the "
                        + "image. They don't see the picture, so they only help once there's a clear "
                        + "subject to search for.")
            }

            Section {
                Label("Connectors power Identify, so they need a vision model. Set one up under "
                      + "Intelligence ▸ Image (install Ollama or add a cloud image model).",
                      systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
                caption("Each connector is optional and independent — Lasso works with none connected: "
                        + "Apple Intelligence, OCR and Translate run on-device. Your AI model is chosen "
                        + "on the Intelligence tab; your keys are stored in the Keychain.")
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

    @ViewBuilder
    private var providerConfig: some View {
        switch draft.provider {
        case .onDevice:
            EmptyView()
        case .ollama:
            modelPicker("Model", selection: $draft.ollamaModel)
        case .mlx:
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: $draft.mlxModel, prompt: Text(MLXProvider.defaultModelID))
                        .frame(minWidth: 150)
                    Menu("Suggested") {
                        ForEach(Self.mlxSuggestions, id: \.id) { suggestion in
                            Button(suggestion.name) { draft.mlxModel = suggestion.id; mlxDownload = .idle }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .onChange(of: draft.mlxModel) { mlxDownload = .idle; refreshMLXRemoteSize() }
            .onAppear { refreshMLXInstalled(); refreshMLXRemoteSize() }

            // One compact status/action row for the selected model.
            HStack(spacing: 8) {
                if mlxDownload == .downloading {
                    mlxProgressView
                } else if MLXProvider.isDownloaded(draft.mlxModel) {
                    Label("On this Mac", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                    if let size = currentModelEntry?.sizeBytes {
                        Text(byteString(size)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { removeCurrentMLXModel() }.controlSize(.small)
                } else {
                    Button(mlxDownloadButtonTitle) { downloadMLXModel() }
                        .disabled(draft.localOnly)
                    Text(draft.localOnly ? "Local-only blocks downloads" : "Downloads once, then runs on-device")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // Other downloaded models (manage/cleanup) — only when there are extras.
            ForEach(otherDownloadedMLX) { entry in
                HStack(spacing: 8) {
                    Text(entry.repoID).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(byteString(entry.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { removeMLXModel(entry) }.controlSize(.small)
                }
            }
        case .openAICompatible:
            Picker("Service", selection: openAIServiceBinding) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                Text("OpenRouter").tag("openrouter")
                Text("Custom").tag("custom")
            }
            if draft.openAIService == "custom" {
                TextField("Base URL", text: $draft.openAICustomBaseURL)
            }
            SecureKeyField("API key", text: openAIKeyField(draft.openAIService))
            cloudModelPicker(selection: openAITextModelField(draft.openAIService), models: openAIModels) {
                await loadCloudModels(); return !openAIModels.isEmpty
            }
        case .anthropic:
            SecureKeyField("API key", text: $draft.anthropicKey)
            cloudModelPicker(selection: $draft.anthropicModel, models: anthropicModels) {
                await loadCloudModels(); return !anthropicModels.isEmpty
            }
        }
    }

    /// Config for the chosen image provider — mirrors `providerConfig`, on the independent vision fields.
    @ViewBuilder
    private var visionProviderConfig: some View {
        switch draft.visionEngine {
        case .matchText:
            EmptyView()
        case .ollama:
            modelPicker("Vision model", selection: $draft.visionModel)
        case .openAICompatible:
            Picker("Service", selection: visionOpenAIServiceBinding) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                Text("OpenRouter").tag("openrouter")
                Text("Custom").tag("custom")
            }
            if draft.visionOpenAIService == "custom" {
                TextField("Base URL", text: $draft.visionOpenAICustomBaseURL)
            }
            SecureKeyField("API key", text: openAIKeyField(draft.visionOpenAIService))
            cloudModelPicker(selection: openAIVisionModelField(draft.visionOpenAIService), models: visionOpenAIModels) {
                await loadVisionModels(); return !visionOpenAIModels.isEmpty
            }
            caption("Shares the API key with your Text provider for the same service.")
        case .anthropic:
            SecureKeyField("API key", text: $draft.visionAnthropicKey)
            cloudModelPicker(selection: $draft.visionAnthropicModel, models: visionAnthropicModels) {
                await loadVisionModels(); return !visionAnthropicModels.isEmpty
            }
        }
    }

    /// Fetch the image provider's cloud model catalog into its picker.
    private func loadVisionModels() async {
        switch draft.visionEngine {
        case .openAICompatible:
            let url = URL(string: draft.visionOpenAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            visionOpenAIModels = await OpenAICompatibleProvider.availableModels(
                baseURL: url, apiKey: draft.visionOpenAIKey)
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

    /// Model row for a cloud provider: a free-text field (manual entry always works) plus a "Load
    /// available models" button that fetches the provider's catalog into a picker — the cloud
    /// equivalent of the Ollama installed-models list.
    /// Cloud model selector — same native pop-up as the Ollama model list, for a uniform design. Auto
    /// -loads the provider's catalog (with a reload button); falls back to a text field when there's
    /// no catalog yet (no key, or a custom endpoint that doesn't expose `/models`).
    @ViewBuilder
    private func cloudModelPicker(selection: Binding<String>, models: [String],
                                  reload: @escaping () async -> Bool) -> some View {
        if models.isEmpty {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: selection, prompt: Text("type a model name"))
                        .labelsHidden().multilineTextAlignment(.trailing).textFieldStyle(.plain)
                    reloadButton(reload)
                }
            }
        } else {
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    Picker("", selection: selection) {
                        let current = selection.wrappedValue
                        if current.isEmpty {
                            Text("Select a model…").tag("")
                        } else if !models.contains(current) {
                            Text("\(current) (custom)").tag(current)
                        }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    reloadButton(reload)
                }
            }
        }
        if let modelLoadNote { caption(modelLoadNote) }
    }

    @ViewBuilder
    private func reloadButton(_ reload: @escaping () async -> Bool) -> some View {
        Button {
            Task {
                loadingModels = true; modelLoadNote = nil
                let found = await reload()
                loadingModels = false
                modelLoadNote = found ? nil : "No models returned — check the base URL and API key."
            }
        } label: {
            if loadingModels { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
        }
        .buttonStyle(.borderless)
        .help("Load available models")
        .disabled(loadingModels)
    }

    /// Fetch the active cloud provider's model catalog into its picker.
    private func loadCloudModels() async {
        switch draft.provider {
        case .openAICompatible:
            let url = URL(string: draft.openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            openAIModels = await OpenAICompatibleProvider.availableModels(
                baseURL: url, apiKey: draft.openAIKey)
        case .anthropic:
            let url = URL(string: draft.anthropicBaseURL) ?? URL(string: "https://api.anthropic.com")!
            anthropicModels = await AnthropicProvider.availableModels(
                baseURL: url, apiKey: draft.anthropicKey)
        default:
            break
        }
    }

    /// "Test connection" + inline result. Validates the *staged* (unsaved) config so the user gets
    /// a clear ✓/✗ before committing, instead of discovering errors at use time.
    @ViewBuilder
    private var connectionRow: some View {
        HStack {
            Button("Test connection") { runTest() }
                .buttonStyle(.bordered)
                .disabled(testState == .testing)
            Spacer()
            testResultView
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
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
                .font(.caption).foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }

    private func runTest() {
        testState = .testing
        Task {
            testState = await ConnectionTest.run(
                provider: draft.provider,
                openAIBaseURL: draft.openAIBaseURL, openAIKey: draft.openAIKey, openAIModel: draft.openAIModel,
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
                return "MLX text is local, but this experiment is text-only for now — choose a dedicated image provider below."
            case .openAICompatible:
                return "Images go to your \(serviceName(draft.openAIBaseURL)) text model — it must be "
                    + "multimodal. Otherwise pick a dedicated image provider below."
            case .anthropic:
                return "Images go to your Anthropic text model — use a vision Claude, or pick a "
                    + "dedicated image provider below."
            }
        case .ollama:
            return "Images are identified locally by Ollama — nothing leaves your Mac."
        case .openAICompatible:
            return "Images are sent to \(serviceName(draft.visionOpenAIBaseURL)) — use a multimodal "
                + "model (e.g. gpt-4o)."
        case .anthropic:
            return "Images are sent to Anthropic — use a vision Claude model (e.g. claude-3-5-sonnet)."
        }
    }

    static let openAIServices = ["openai", "groq", "openrouter", "custom"]

    /// Base URL for a known service preset, or the user's custom URL.
    // MARK: - MLX download

    private var mlxStatusText: String {
        switch mlxDownload {
        case .downloading: "Downloading… first time can take a few minutes"
        case .ready: "Ready — model is on this Mac"
        case .failed(let message): message
        case .idle:
            draft.localOnly ? "Local-only mode blocks downloads"
                : (MLXProvider.isDownloaded(draft.mlxModel) ? "Ready — model is on this Mac" : "Not downloaded")
        }
    }

    private var mlxStatusColor: Color {
        switch mlxDownload {
        case .failed: .orange
        case .ready: .green
        default: .secondary
        }
    }

    @ViewBuilder
    private var mlxProgressView: some View {
        if let total = mlxRemoteSize, total > 0 {
            ProgressView(value: mlxProgress).frame(width: 90)
            Text("\(Int(mlxProgress * 100))% · \(byteString(mlxDownloadedBytes)) / \(byteString(total))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else {
            ProgressView().controlSize(.small)
            Text(mlxDownloadedBytes > 0
                 ? "Downloading… \(byteString(mlxDownloadedBytes))"
                 : "Downloading… first time can take a few minutes")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func downloadMLXModel() {
        let id = draft.mlxModel
        mlxDownload = .downloading
        mlxProgress = 0
        mlxDownloadedBytes = 0
        let total = mlxRemoteSize
        let dir = MLXCache.directory(for: id)

        // The loader doesn't surface progress, so derive a real % by watching the cache dir grow
        // against the known total size.
        let poll = Task {
            while !Task.isCancelled {
                let onDisk = await Task.detached { MLXCache.size(of: dir) }.value
                mlxDownloadedBytes = onDisk
                if let total, total > 0 { mlxProgress = min(1, Double(onDisk) / Double(total)) }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        Task {
            do {
                try await MLXProvider.ensureDownloaded(id)
                poll.cancel()
                mlxProgress = 1
                mlxDownload = .ready
            } catch {
                poll.cancel()
                mlxDownload = .failed(error.localizedDescription)
            }
            refreshMLXInstalled()
        }
    }

    private var mlxDownloadButtonTitle: String {
        let base = MLXProvider.isDownloaded(draft.mlxModel) ? "Re-download" : "Download model"
        if mlxSizeLoading { return base + " · checking size…" }
        if let size = mlxRemoteSize { return base + " · ≈ \(byteString(size))" }
        return base
    }

    private var currentModelEntry: MLXCache.Entry? {
        mlxInstalled.first { MLXProvider.normalizedID($0.repoID) == MLXProvider.normalizedID(draft.mlxModel) }
    }

    private var otherDownloadedMLX: [MLXCache.Entry] {
        mlxInstalled.filter { MLXProvider.normalizedID($0.repoID) != MLXProvider.normalizedID(draft.mlxModel) }
    }

    private func removeCurrentMLXModel() {
        if let entry = currentModelEntry { removeMLXModel(entry) }
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

    nonisolated static func openAIServiceURL(_ service: String, custom: String) -> String {
        switch service {
        case "openai": "https://api.openai.com/v1"
        case "groq": "https://api.groq.com/openai/v1"
        case "openrouter": "https://openrouter.ai/api/v1"
        default: custom.isEmpty ? "https://api.openai.com/v1" : custom
        }
    }

    /// Infer the service id from a stored base URL (for migration / first load).
    static func openAIServiceID(forURL urlString: String) -> String {
        let host = (URL(string: urlString)?.host ?? "").lowercased()
        if host.contains("groq") { return "groq" }
        if host.contains("openrouter") { return "openrouter" }
        if host.contains("openai") { return "openai" }
        return "custom"
    }

    /// Service pickers: switching just changes the active service (the key/model fields bind straight
    /// into the per-service dicts, so each service keeps its own) and reloads that service's catalog.
    private var openAIServiceBinding: Binding<String> {
        Binding(get: { draft.openAIService },
                set: { draft.openAIService = $0; openAIModels = []; Task { await loadCloudModels() } })
    }
    private var visionOpenAIServiceBinding: Binding<String> {
        Binding(get: { draft.visionOpenAIService },
                set: { draft.visionOpenAIService = $0; visionOpenAIModels = []; Task { await loadVisionModels() } })
    }

    /// Per-service field bindings (the shared key, and each role's model).
    private func openAIKeyField(_ service: String) -> Binding<String> {
        Binding(get: { draft.openAIKeyByService[service] ?? "" },
                set: { draft.openAIKeyByService[service] = $0 })
    }
    private func openAITextModelField(_ service: String) -> Binding<String> {
        Binding(get: { draft.openAIModelByService[service] ?? "" },
                set: { draft.openAIModelByService[service] = $0 })
    }
    private func openAIVisionModelField(_ service: String) -> Binding<String> {
        Binding(get: { draft.visionOpenAIModelByService[service] ?? "" },
                set: { draft.visionOpenAIModelByService[service] = $0 })
    }

    private var privacyLine: String {
        if draft.localOnly, !draft.provider.isLocalKind {
            return "Local-only is on, but \(serviceName(draft.openAIBaseURL)) is a cloud model — your "
                + "selection still goes to that endpoint. Use Apple or Ollama for full isolation."
        }
        switch draft.provider {
        case .onDevice, .ollama, .mlx:
            return "Runs on this Mac — nothing leaves your device."
        case .openAICompatible:
            return serviceName(draft.openAIBaseURL) == "a local server"
                ? "Local server — stays on this Mac."
                : "Cloud — your selection is sent to \(serviceName(draft.openAIBaseURL)). Use a multimodal model for image questions."
        case .anthropic:
            return "Cloud — your selection is sent to Anthropic. A vision Claude model also handles images."
        }
    }

    private func serviceName(_ urlString: String) -> String {
        let host = (URL(string: urlString)?.host ?? "").lowercased()
        if host.contains("groq") { return "Groq" }
        if host.contains("openrouter") { return "OpenRouter" }
        if host.contains("openai") { return "OpenAI" }
        if host == "localhost" || host == "127.0.0.1" { return "a local server" }
        return "the provider"
    }

    private var noModels: Bool { modelsLoaded && availableModels.isEmpty }

    /// Dropdown of installed Ollama models, with the "auto" choice + a "(not installed)" fallback
    /// for a saved name that's no longer present.
    @ViewBuilder
    private func modelPicker(_ label: String, selection: Binding<String>,
                             autoLabel: String = "Auto") -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if noModels {
                    Text("No Ollama models").foregroundStyle(.secondary)
                } else {
                    Picker("", selection: selection) {
                        Text(autoLabel).tag("")
                        let current = selection.wrappedValue
                        if !current.isEmpty, !availableModels.contains(current) {
                            Text("\(current) (not installed)").tag(current)
                        }
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Button { reloadOllamaModels() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh installed models")
            }
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
        var d = Draft()
        d.provider = intelligence.preferred
        d.ollamaModel = intelligence.ollamaModel
        d.ollamaBaseURL = OllamaEndpoint.customURLString
        d.ollamaAutoStart = UserDefaults.standard.bool(forKey: "ollama.autoStart")
        d.mlxModel = intelligence.mlxModel
        d.visionModel = intelligence.visionModel
        d.anthropicBaseURL = intelligence.anthropicBaseURL
        d.anthropicModel = intelligence.anthropicModel
        d.anthropicKey = Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? ""
        d.visionEngine = intelligence.visionEngine
        d.visionAnthropicBaseURL = intelligence.visionAnthropicBaseURL
        d.visionAnthropicModel = intelligence.visionAnthropicModel
        d.visionAnthropicKey = Keychain.get("vision.anthropic.apiKey") ?? ""
        // OpenAI-compatible: shared per-service key store + per-role model stores.
        let oaSvc = UserDefaults.standard.string(forKey: "intelligence.openai.service")
            ?? Self.openAIServiceID(forURL: intelligence.openAIBaseURL)
        d.openAIService = oaSvc
        d.openAICustomBaseURL = UserDefaults.standard.string(forKey: "intelligence.openai.customBaseURL")
            ?? (oaSvc == "custom" ? intelligence.openAIBaseURL : "https://api.openai.com/v1")
        let voaSvc = UserDefaults.standard.string(forKey: "intelligence.vision.openai.service")
            ?? Self.openAIServiceID(forURL: intelligence.visionOpenAIBaseURL)
        d.visionOpenAIService = voaSvc
        d.visionOpenAICustomBaseURL = UserDefaults.standard.string(forKey: "intelligence.vision.openai.customBaseURL")
            ?? (voaSvc == "custom" ? intelligence.visionOpenAIBaseURL : "https://api.openai.com/v1")
        for s in Self.openAIServices {
            d.openAIKeyByService[s] = Keychain.get("openai.svc.\(s).key") ?? ""
            d.openAIModelByService[s] = UserDefaults.standard.string(forKey: "intelligence.openai.svc.\(s).model") ?? ""
            d.visionOpenAIModelByService[s] = UserDefaults.standard.string(forKey: "intelligence.vision.openai.svc.\(s).model") ?? ""
        }
        // Migrate legacy single keys into the shared per-service store.
        if (d.openAIKeyByService[oaSvc] ?? "").isEmpty {
            d.openAIKeyByService[oaSvc] = Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? ""
        }
        if (d.openAIKeyByService[voaSvc] ?? "").isEmpty {
            d.openAIKeyByService[voaSvc] = Keychain.get("vision.openai.apiKey") ?? ""
        }
        if (d.openAIModelByService[oaSvc] ?? "").isEmpty, !intelligence.openAIModel.isEmpty {
            d.openAIModelByService[oaSvc] = intelligence.openAIModel
        }
        if (d.visionOpenAIModelByService[voaSvc] ?? "").isEmpty, !intelligence.visionOpenAIModel.isEmpty {
            d.visionOpenAIModelByService[voaSvc] = intelligence.visionOpenAIModel
        }

        for connector in Connectors.all {
            d.connectorEnabled[connector.id] = connector.isEnabled
            if connector.keyAccount != nil { d.connectorKeys[connector.id] = connector.key() }
        }
        d.localOnly = UserDefaults.standard.bool(forKey: "privacy.localOnly")
        d.pretranslate = UserDefaults.standard.object(forKey: "translation.pretranslate") as? Bool ?? true
        d.launchAtLogin = LoginItem.isEnabled
        // Heal an inconsistent saved state (local-only + a cloud engine / cloud image provider).
        if d.localOnly, !d.provider.isLocalKind { d.provider = .onDevice }
        if d.localOnly, d.visionEngine == .openAICompatible || d.visionEngine == .anthropic {
            d.visionEngine = .ollama
        }
        draft = d
        saved = d
        // Pre-load the cloud catalogs if a cloud engine/image provider is already configured.
        await loadCloudModels()
        await loadVisionModels()
    }

    private func apply() {
        // Local-only must mean local: a cloud engine / cloud image provider is committed as local.
        if draft.localOnly, !draft.provider.isLocalKind { draft.provider = .onDevice }
        if draft.localOnly, draft.visionEngine == .openAICompatible || draft.visionEngine == .anthropic {
            draft.visionEngine = .ollama
        }
        intelligence.preferred = draft.provider
        intelligence.ollamaModel = draft.ollamaModel
        intelligence.mlxModel = draft.mlxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        OllamaEndpoint.customURLString = draft.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(draft.ollamaAutoStart, forKey: "ollama.autoStart")
        Task { await OllamaEndpoint.autodetect() }   // re-resolve the effective server after a change
        intelligence.visionModel = draft.visionModel
        intelligence.anthropicBaseURL = draft.anthropicBaseURL
        intelligence.anthropicModel = draft.anthropicModel
        Keychain.set(draft.anthropicKey, for: "anthropic.apiKey")
        intelligence.visionEngine = draft.visionEngine
        intelligence.visionAnthropicBaseURL = draft.visionAnthropicBaseURL
        intelligence.visionAnthropicModel = draft.visionAnthropicModel
        Keychain.set(draft.visionAnthropicKey, for: "vision.anthropic.apiKey")

        // OpenAI-compatible: persist the shared per-service key + each role's per-service model, then
        // commit the active service of each role as the coordinator's effective config.
        for s in Self.openAIServices {
            Keychain.set(draft.openAIKeyByService[s] ?? "", for: "openai.svc.\(s).key")
            UserDefaults.standard.set(draft.openAIModelByService[s] ?? "", forKey: "intelligence.openai.svc.\(s).model")
            UserDefaults.standard.set(draft.visionOpenAIModelByService[s] ?? "", forKey: "intelligence.vision.openai.svc.\(s).model")
        }
        UserDefaults.standard.set(draft.openAIService, forKey: "intelligence.openai.service")
        UserDefaults.standard.set(draft.openAICustomBaseURL, forKey: "intelligence.openai.customBaseURL")
        UserDefaults.standard.set(draft.visionOpenAIService, forKey: "intelligence.vision.openai.service")
        UserDefaults.standard.set(draft.visionOpenAICustomBaseURL, forKey: "intelligence.vision.openai.customBaseURL")
        // Active text config
        intelligence.openAIBaseURL = Self.openAIServiceURL(draft.openAIService, custom: draft.openAICustomBaseURL)
        intelligence.openAIModel = draft.openAIModelByService[draft.openAIService] ?? ""
        Keychain.set(draft.openAIKeyByService[draft.openAIService] ?? "", for: "openai.apiKey")
        // Active image config (key shared from the same per-service store)
        intelligence.visionOpenAIBaseURL = Self.openAIServiceURL(draft.visionOpenAIService, custom: draft.visionOpenAICustomBaseURL)
        intelligence.visionOpenAIModel = draft.visionOpenAIModelByService[draft.visionOpenAIService] ?? ""
        Keychain.set(draft.openAIKeyByService[draft.visionOpenAIService] ?? "", for: "vision.openai.apiKey")

        for connector in Connectors.all {
            UserDefaults.standard.set(draft.connectorEnabled[connector.id] ?? connector.defaultEnabled,
                                      forKey: connector.enabledKey)
            if let account = connector.keyAccount {
                Keychain.set(draft.connectorKeys[connector.id] ?? "", for: account)
            }
        }
        UserDefaults.standard.set(draft.localOnly, forKey: "privacy.localOnly")
        UserDefaults.standard.set(draft.pretranslate, forKey: "translation.pretranslate")
        if draft.launchAtLogin != saved.launchAtLogin { LoginItem.set(draft.launchAtLogin) }
        Task { await intelligence.refreshVisionAvailability() }   // re-grey vision features as needed
        saved = draft
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

/// A masked API-key field with a show/hide toggle — keys are sensitive, so they're hidden by
/// default but revealable to check a paste.
private struct SecureKeyField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide key" : "Show key")
        }
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
                    SecureKeyField("\(connector.name) API key", text: $key)
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
                .disabled(test == .testing || (connector.requiresKey && key.isEmpty))
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
