import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Bindable var intelligence: IntelligenceCoordinator
    @State private var launchAtLogin = LoginItem.isEnabled
    @AppStorage("translation.pretranslate") private var pretranslate = true
    @AppStorage("imageSearch.enabled") private var imageSearch = false
    @AppStorage("reddit.clientID") private var redditClientID = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            intelligenceTab.tabItem { Label("Intelligence", systemImage: "sparkles") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
        .padding(20)
    }

    // MARK: General

    private var general: some View {
        Form {
            KeyboardShortcuts.Recorder("Capture shortcut:", name: .capture)

            Toggle("Launch Lasso at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LoginItem.set(newValue)
                }

            Toggle("Pre-translate selections", isOn: $pretranslate)
            Text("Translate foreign text in the background as you select it, so tapping Translate is instant. On-device only; skipped on large selections and in Low Power Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Press the shortcut to freeze the screen and select a region.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    TextField("Text model", text: $intelligence.ollamaModel)
                }
            } header: {
                Text("Text & reasoning")
            } footer: {
                Text(intelligence.preferred == .ollama
                     ? "Used for summaries/answers. Requires `ollama serve` running locally (default: gpt-oss:20b). Runs on this Mac."
                     : "Apple Intelligence runs fully on-device; falls back to your local Ollama model if unavailable. Nothing leaves this Mac.")
            }

            Section {
                TextField("Vision model", text: $intelligence.visionModel)
                Toggle("Web lookup", isOn: $imageSearch)
                TextField("Reddit client ID", text: $redditClientID)
            } header: {
                Text("Identify")
            } footer: {
                Text("Vision model is a local Ollama model that \u{201C}sees\u{201D} the image — pull one first, e.g. `ollama pull qwen3-vl:2b`. Web lookup adds TinEye, DuckDuckGo, and Reddit (the only thing that leaves your Mac). Reddit needs a free client ID — create an \u{201C}installed app\u{201D} at reddit.com/prefs/apps (no login or secret).")
            }
        }
        .formStyle(.grouped)
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
