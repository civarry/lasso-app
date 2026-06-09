import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Bindable var intelligence: IntelligenceCoordinator

    /// All editable settings are staged here and committed together via "Save & Apply" — one place
    /// to save, instead of a Save button per field.
    private struct Draft: Equatable {
        var provider: ProviderKind = .onDevice
        var ollamaModel = ""
        var visionModel = ""
        var openAIBaseURL = "https://api.openai.com/v1"
        var openAIModel = "gpt-4o-mini"
        var openAIKey = ""
        var anthropicBaseURL = "https://api.anthropic.com"
        var anthropicModel = "claude-3-5-haiku-latest"
        var anthropicKey = ""
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
            Section("Capture") {
                KeyboardShortcuts.Recorder("Shortcut", name: .capture)
                Toggle("Launch at login", isOn: $draft.launchAtLogin)
            }
            Section("Privacy") {
                Toggle("Local-only mode", isOn: $draft.localOnly)
                caption("Contacts nothing but your chosen model endpoint — turns off web search, "
                        + "favicons, and every incidental network call. Recommended on managed or "
                        + "work Macs. On-device or Ollama keeps everything on this machine.")
            }
            Section("Translation") {
                Toggle("Pre-translate selections", isOn: $draft.pretranslate)
                caption("Translates foreign text in the background so Translate is instant. On-device only.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Intelligence

    private var intelligenceTab: some View {
        Form {
            Section("Model provider") {
                Picker("Engine", selection: $draft.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                providerConfig
                connectionRow
                caption(privacyLine)
            }

            Section("Identify") {
                imageModelRow
                caption("Add web search, reverse-image and other tools in the Connectors tab.")
            }
        }
        .formStyle(.grouped)
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

    @ViewBuilder
    private var providerConfig: some View {
        switch draft.provider {
        case .onDevice:
            EmptyView()
        case .ollama:
            modelPicker("Model", selection: $draft.ollamaModel)
        case .openAICompatible:
            Picker("Service", selection: openAIPreset) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                Text("OpenRouter").tag("openrouter")
                Text("Custom").tag("custom")
            }
            TextField("Base URL", text: $draft.openAIBaseURL)
            TextField("Model", text: $draft.openAIModel)
            SecureKeyField("API key", text: $draft.openAIKey)
        case .anthropic:
            TextField("Model", text: $draft.anthropicModel)
            SecureKeyField("API key", text: $draft.anthropicKey)
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

    /// The "Image model" row — always shown as an optional override (picking a local vision model
    /// wins for *any* engine). "Use main model" defers to the engine: the cloud model for cloud
    /// engines, or the best installed vision model locally. The caption explains the active path.
    @ViewBuilder
    private var imageModelRow: some View {
        modelPicker("Image model", selection: $draft.visionModel, autoLabel: "Use main model")
        caption(imageModelHint)
    }

    private var imageModelHint: String {
        if !draft.visionModel.isEmpty {
            return "Images are handled locally by \(draft.visionModel) — overrides the engine above."
        }
        switch draft.provider {
        case .onDevice:
            return "Apple Intelligence is text-only — images use your best installed Ollama vision "
                + "model. Pick one above to be explicit."
        case .ollama:
            return mainOllamaIsVision
                ? "Your main model already handles images — nothing else needed."
                : "“Use main model” picks your best installed vision model for images."
        case .openAICompatible:
            return "“Use main model” sends images to your \(serviceName(draft.openAIBaseURL)) model "
                + "(must be multimodal). Pick a local vision model above to handle images on-device instead."
        case .anthropic:
            return "“Use main model” sends images to your Anthropic model. Pick a local vision model "
                + "above to handle images on-device instead."
        }
    }

    private var mainOllamaIsVision: Bool {
        !draft.ollamaModel.isEmpty && OllamaModels.isVision(draft.ollamaModel)
    }

    /// Quick presets that fill the OpenAI-compatible base URL (Custom leaves it editable).
    private var openAIPreset: Binding<String> {
        Binding(
            get: {
                let host = (URL(string: draft.openAIBaseURL)?.host ?? "").lowercased()
                if host.contains("groq") { return "groq" }
                if host.contains("openrouter") { return "openrouter" }
                if host.contains("openai") { return "openai" }
                return "custom"
            },
            set: { id in
                switch id {
                case "openai": draft.openAIBaseURL = "https://api.openai.com/v1"
                case "groq": draft.openAIBaseURL = "https://api.groq.com/openai/v1"
                case "openrouter": draft.openAIBaseURL = "https://openrouter.ai/api/v1"
                default: break
                }
            })
    }

    private var privacyLine: String {
        if draft.localOnly, !draft.provider.isLocalKind {
            return "Local-only is on, but \(serviceName(draft.openAIBaseURL)) is a cloud model — your "
                + "selection still goes to that endpoint. Use Apple or Ollama for full isolation."
        }
        switch draft.provider {
        case .onDevice, .ollama:
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
        if noModels {
            LabeledContent(label) { Text("No Ollama models").foregroundStyle(.secondary) }
        } else {
            Picker(label, selection: selection) {
                Text(autoLabel).tag("")
                let current = selection.wrappedValue
                if !current.isEmpty, !availableModels.contains(current) {
                    Text("\(current) (not installed)").tag(current)
                }
                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
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
        d.visionModel = intelligence.visionModel
        d.openAIBaseURL = intelligence.openAIBaseURL
        d.openAIModel = intelligence.openAIModel
        d.anthropicBaseURL = intelligence.anthropicBaseURL
        d.anthropicModel = intelligence.anthropicModel
        d.openAIKey = Keychain.getMigrating("openai.apiKey", legacyDefaultsKey: "openai.apiKey") ?? ""
        d.anthropicKey = Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? ""
        for connector in Connectors.all {
            d.connectorEnabled[connector.id] = connector.isEnabled
            if connector.keyAccount != nil { d.connectorKeys[connector.id] = connector.key() }
        }
        d.localOnly = UserDefaults.standard.bool(forKey: "privacy.localOnly")
        d.pretranslate = UserDefaults.standard.object(forKey: "translation.pretranslate") as? Bool ?? true
        d.launchAtLogin = LoginItem.isEnabled
        draft = d
        saved = d
    }

    private func apply() {
        intelligence.preferred = draft.provider
        intelligence.ollamaModel = draft.ollamaModel
        intelligence.visionModel = draft.visionModel
        intelligence.openAIBaseURL = draft.openAIBaseURL
        intelligence.openAIModel = draft.openAIModel
        intelligence.anthropicBaseURL = draft.anthropicBaseURL
        intelligence.anthropicModel = draft.anthropicModel
        Keychain.set(draft.openAIKey, for: "openai.apiKey")
        Keychain.set(draft.anthropicKey, for: "anthropic.apiKey")
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
            return up
                ? .failure("Ollama is running but has no models. Try `ollama pull qwen3:4b`.")
                : .failure("Can't reach Ollama at localhost:11434. Is `ollama serve` running?")

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
