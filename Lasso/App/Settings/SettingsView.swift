import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Bindable var intelligence: IntelligenceCoordinator
    @State private var launchAtLogin = LoginItem.isEnabled
    @AppStorage("translation.pretranslate") private var pretranslate = true
    @AppStorage("imageSearch.enabled") private var imageSearch = false
    @AppStorage("tavily.apiKey") private var tavilyKey = ""
    @AppStorage("serpapi.apiKey") private var serpKey = ""
    @State private var availableModels: [String] = []
    @State private var modelsLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                intelligenceTab.tabItem { Label("Intelligence", systemImage: "sparkles") }
                about.tabItem { Label("About", systemImage: "info.circle") }
            }

            Label("Selections and toggles apply instantly · API keys use Save.",
                  systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        }
        .frame(width: 540, height: 580)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Capture shortcut:", name: .capture)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Press the shortcut to freeze the screen and select a region to act on.")
            }

            Section {
                Toggle("Launch Lasso at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItem.set(newValue)
                    }
            } header: {
                Text("Startup")
            } footer: {
                Text("Lasso lives in the menu bar and stays out of your way until you call it.")
            }

            Section {
                Toggle("Pre-translate selections", isOn: $pretranslate)
            } header: {
                Text("Translation")
            } footer: {
                Text("Translate foreign text in the background as you select it, so tapping Translate is instant. On-device only; skipped on large selections and in Low Power Mode.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Intelligence

    private var intelligenceTab: some View {
        Form {
            Section {
                Picker("AI provider", selection: $intelligence.preferred) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if intelligence.preferred == .ollama {
                    modelPicker("Text model", selection: $intelligence.ollamaModel)
                }
            } header: {
                Text("Text & reasoning")
            } footer: {
                Text(noModels
                     ? "No Ollama models detected. Install Ollama from ollama.com and pull one, e.g. `ollama pull gpt-oss:20b`, then reopen Settings."
                     : intelligence.preferred == .ollama
                     ? "Used for summaries/answers. Runs locally via Ollama — nothing leaves this Mac."
                     : "Apple Intelligence runs fully on-device; falls back to your local Ollama model if unavailable. Nothing leaves this Mac.")
            }

            Section {
                modelPicker("Vision model", selection: $intelligence.visionModel)
                Toggle("Web lookup", isOn: $imageSearch)
                APIKeyField(title: "Tavily API key", stored: $tavilyKey)
                APIKeyField(title: "SerpApi key", stored: $serpKey)
                if !tavilyKey.isEmpty || !serpKey.isEmpty {
                    Label("This month — Tavily \(SearchQuota.usedMonth("tavily"))/\(SearchQuota.caps["tavily"]?.monthly ?? 0) · SerpApi \(SearchQuota.usedMonth("serpapi"))/\(SearchQuota.caps["serpapi"]?.monthly ?? 0). Repeats are cached (free).",
                          systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("Identify")
            } footer: {
                Text("Vision model is a local Ollama model that \u{201C}sees\u{201D} the image — pull one first, e.g. `ollama pull qwen3-vl:2b`. Web lookup (the only thing that leaves your Mac) uses Tavily/SerpApi first (best results, budget-paced + cached), with Wikipedia, TinEye, DuckDuckGo and Reddit as the free baseline. Get free keys at tavily.com (1,000 credits/mo) and serpapi.com (250/mo).")
            }
        }
        .formStyle(.grouped)
        .task { availableModels = await OllamaModels.installed(); modelsLoaded = true }
    }

    private var noModels: Bool { modelsLoaded && availableModels.isEmpty }

    /// Dropdown of installed Ollama models. Shows an empty state when none are detected, and keeps
    /// the current value selectable even if it isn't installed (flagged "not installed").
    @ViewBuilder
    private func modelPicker(_ label: String, selection: Binding<String>) -> some View {
        if noModels {
            LabeledContent(label) { Text("No models found").foregroundStyle(.secondary) }
        } else {
            Picker(label, selection: selection) {
                let current = selection.wrappedValue
                if !current.isEmpty, !availableModels.contains(current) {
                    Text("\(current) (not installed)").tag(current)
                }
                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "lasso")
                .font(.system(size: 40))
            Text("Lasso").font(.title2).bold()
            Text("On-device screen intelligence for Apple Silicon.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(intelligence.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

/// Text field for an API key with an explicit commit: shows a "Save" button while the draft differs
/// from the stored value, and a green check once saved — so typed changes feel intentional.
private struct APIKeyField: View {
    let title: String
    @Binding var stored: String
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $draft)
                .onSubmit { commit() }
            Button("Save") { commit() }
                .buttonStyle(.borderless)
                .foregroundStyle(hasChanges ? Color.accentColor : Color.secondary)
                .disabled(!hasChanges)
        }
        .onAppear { draft = stored }
    }

    private var hasChanges: Bool { draft != stored }

    private func commit() {
        guard hasChanges else { return }
        stored = draft
    }
}
