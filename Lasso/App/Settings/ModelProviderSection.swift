import SwiftUI

// MARK: - Section inputs

/// One entry in a section's Protocol pop-up. A protocol is the API interface a backend speaks
/// (OpenAI-compatible, Anthropic, Ollama, MLX, Apple on-device) — not an endpoint, and not a choice
/// of which credential to use.
struct ProviderChoice: Identifiable, Hashable {
    let id: String
    let label: String
}

/// The explicit "this section follows another one" state, for a section that can be derived (today:
/// Image, which can run whatever the Language model runs). Making it a switch is the point — the
/// alternative is a second, visually independent block silently holding the same endpoint and model.
struct InheritanceConfig {
    var title: String
    var isOn: Binding<Bool>
    var note: String
}

/// The Connections summary row, for a protocol that supports **many simultaneous connections**.
///
/// There is no active connection: every configured endpoint is live and contributes its models to
/// the Model picker above, and choosing a model is what decides where the request goes. So this row
/// reports a count and reachability, and hands off to the manager — it never selects.
struct ConnectionsRowConfig {
    var summary: String
    var statusText: String
    var statusTint: Color
    var isTesting: Bool
    var canTest: Bool
    var onTest: () -> Void
    var onManage: () -> Void
}

/// The masked API-key row, for a protocol that has exactly one endpoint (Anthropic) and therefore no
/// connection list to manage.
struct APIKeyRowConfig {
    var value: Binding<String>
    var caption: String?
    var onClear: (() -> Void)?
}

/// "Test connection" for a single-endpoint protocol.
struct TestRowConfig {
    var outcome: ConnectionTest.Outcome
    var successText: String?
    var run: () -> Void
    var note: String?
}

// MARK: - The section template

/// One model-type section — Language, Image, Embedding, and anything added later.
///
/// The shape encodes the architecture: **Protocol → many Connections → aggregated Models → you pick a
/// model.** Connections are configuration and live behind "Manage connections"; the model is the
/// selection and sits high in the card. The row order, the two-half grid, the control widths, the
/// button styles and the spacing all live here, once. A section is an instance: it supplies its
/// protocol list and the contents of the variable slots, never its own layout.
struct ModelProviderSection<ModelControl: View, Extras: View, ContextControl: View>: View {
    let title: String
    let providers: [ProviderChoice]
    @Binding var providerID: String
    var providerCaption: String?
    /// Non-nil only for a section that can be derived from another one.
    var inheritance: InheritanceConfig?
    var showsModelRow: Bool = true
    var modelCaption: String?
    @ViewBuilder var modelControl: () -> ModelControl
    /// Protocol-specific rows (an MLX downloader, a custom model id). Built from `SettingsRow`, so
    /// they land on the same grid as everything else.
    @ViewBuilder var extras: () -> Extras
    @ViewBuilder var contextControl: () -> ContextControl
    /// Many-connection protocols get this; single-endpoint ones get `apiKey` + `test` instead.
    var connections: ConnectionsRowConfig?
    var apiKey: APIKeyRowConfig?
    var test: TestRowConfig?
    var footnote: String

    private var isInherited: Bool { inheritance?.isOn.wrappedValue ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard(title: title) {
                if let inheritance {
                    SettingsRow(inheritance.title, symbol: "link", caption: inheritance.note) {
                        SettingsSwitch(title: "", isOn: inheritance.isOn)
                    }
                }

                if !isInherited {
                    SettingsRow("Protocol", caption: providerCaption) {
                        Picker("", selection: $providerID) {
                            ForEach(providers) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    if showsModelRow {
                        SettingsRow("Model", caption: modelCaption) { modelControl() }
                    }

                    extras()
                    contextControl()

                    if let apiKey {
                        SettingsRow("API Key", caption: apiKey.caption) {
                            SettingsKeyField(text: apiKey.value, placeholder: "Paste your key",
                                             onClear: apiKey.onClear)
                                .settingsFieldWidth()
                        }
                    }

                    if let connections { connectionsRow(connections) }
                    if let test { testRow(test) }
                }
            }

            if !isInherited, let connections {
                Button("Manage connections") { connections.onManage() }
                    .buttonStyle(.link)
                    .font(SettingsFont.sub)
                    .padding(.leading, 2)
            }

            if !footnote.isEmpty {
                Text(footnote)
                    .font(SettingsFont.sub)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func connectionsRow(_ config: ConnectionsRowConfig) -> some View {
        SettingsRow("Connections", caption: config.summary) {
            Button("Test connections", action: config.onTest)
                .buttonStyle(.bordered)
                .disabled(!config.canTest || config.isTesting)
            SettingsStatusChip(text: config.statusText, tint: config.statusTint,
                               busy: config.isTesting)
        }
    }

    @ViewBuilder
    private func testRow(_ config: TestRowConfig) -> some View {
        SettingsRow("Connection") {
            Button("Test connection", action: config.run)
                .buttonStyle(.bordered)
                .disabled(config.outcome == .testing)

            switch config.outcome {
            case .idle:
                if let note = config.note {
                    SettingsStatusChip(text: note, tint: .green)
                }
            case .testing:
                SettingsStatusChip(text: "Testing…", tint: .secondary, busy: true)
            case .ok(let ms):
                SettingsStatusChip(text: config.successText ?? "Connected · \(ms) ms", tint: .green)
            case .failure(let message):
                SettingsStatusChip(text: message, tint: .orange)
            }
        }
    }
}
