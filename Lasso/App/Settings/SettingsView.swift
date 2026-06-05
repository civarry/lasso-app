import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Bindable var intelligence: IntelligenceCoordinator
    @State private var launchAtLogin = LoginItem.isEnabled

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

            Text("Press the shortcut to freeze the screen and select a region.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Intelligence

    private var intelligenceTab: some View {
        Form {
            Picker("AI provider:", selection: $intelligence.preferred) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            if intelligence.preferred == .ollama {
                TextField("Ollama model:", text: $intelligence.ollamaModel)
                    .textFieldStyle(.roundedBorder)
                Text("Requires `ollama serve` running locally. Default: gpt-oss:20b.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apple Intelligence runs fully on-device. If it's unavailable, Lasso falls back to your local Ollama model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("Both options run on this Mac — nothing is sent to a cloud service.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
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
