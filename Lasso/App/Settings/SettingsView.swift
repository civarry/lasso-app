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
        var tavilyKey = ""
        var serpKey = ""
        var webLookup = false
        var pretranslate = true
        var launchAtLogin = false
    }

    @State private var draft = Draft()
    @State private var saved = Draft()
    @State private var availableModels: [String] = []
    @State private var modelsLoaded = false

    private var isDirty: Bool { draft != saved }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                intelligenceTab.tabItem { Label("Intelligence", systemImage: "sparkles") }
                about.tabItem { Label("About", systemImage: "info.circle") }
            }
            actionBar
        }
        .frame(width: 540, height: 600)
        .task { await load() }
    }

    // MARK: - Save & Apply bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.tertiary)
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
            Section("Provider") {
                Picker("Engine", selection: $draft.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                providerConfig
                caption(privacyLine)
            }

            Section("Identify") {
                modelPicker("Vision model", selection: $draft.visionModel)
                Toggle("Web search", isOn: $draft.webLookup)
                if draft.webLookup {
                    TextField("Tavily key (optional)", text: $draft.tavilyKey)
                    TextField("SerpApi key (optional)", text: $draft.serpKey)
                    if !draft.tavilyKey.isEmpty || !draft.serpKey.isEmpty {
                        caption("This month — Tavily \(SearchQuota.usedMonth("tavily"))/\(SearchQuota.caps["tavily"]?.monthly ?? 0) · SerpApi \(SearchQuota.usedMonth("serpapi"))/\(SearchQuota.caps["serpapi"]?.monthly ?? 0)")
                    }
                }
                caption("Reverse-image + web context for Identify. Free keys add stronger results.")
            }
        }
        .formStyle(.grouped)
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
            TextField("API key", text: $draft.openAIKey)
            TextField("Model", text: $draft.openAIModel)
        case .anthropic:
            TextField("API key", text: $draft.anthropicKey)
            TextField("Model", text: $draft.anthropicModel)
        }
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
        switch draft.provider {
        case .onDevice, .ollama:
            "Runs on this Mac — nothing leaves your device."
        case .openAICompatible:
            serviceName(draft.openAIBaseURL) == "a local server"
                ? "Local server — stays on this Mac."
                : "Cloud — your selection is sent to \(serviceName(draft.openAIBaseURL)). Use a multimodal model for image questions."
        case .anthropic:
            "Cloud — your selection is sent to Anthropic. A vision Claude model also handles images."
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

    /// Dropdown of installed Ollama models, with Auto + a "(not installed)" fallback for a saved name.
    @ViewBuilder
    private func modelPicker(_ label: String, selection: Binding<String>) -> some View {
        if noModels {
            LabeledContent(label) { Text("No Ollama models").foregroundStyle(.secondary) }
        } else {
            Picker(label, selection: selection) {
                Text("Auto").tag("")
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
        VStack(spacing: 8) {
            Image(systemName: "lasso").font(.system(size: 40))
            Text("Lasso").font(.title2).bold()
            Text("On-device screen intelligence for Apple Silicon.")
                .font(.callout).foregroundStyle(.secondary)
            Text(intelligence.privacyNote)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding()
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
        d.tavilyKey = Keychain.getMigrating("tavily.apiKey", legacyDefaultsKey: "tavily.apiKey") ?? ""
        d.serpKey = Keychain.getMigrating("serpapi.apiKey", legacyDefaultsKey: "serpapi.apiKey") ?? ""
        d.webLookup = UserDefaults.standard.bool(forKey: "imageSearch.enabled")
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
        Keychain.set(draft.tavilyKey, for: "tavily.apiKey")
        Keychain.set(draft.serpKey, for: "serpapi.apiKey")
        UserDefaults.standard.set(draft.webLookup, forKey: "imageSearch.enabled")
        UserDefaults.standard.set(draft.pretranslate, forKey: "translation.pretranslate")
        if draft.launchAtLogin != saved.launchAtLogin { LoginItem.set(draft.launchAtLogin) }
        saved = draft
    }
}
