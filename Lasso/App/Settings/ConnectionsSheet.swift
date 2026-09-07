import SwiftUI

/// Manage the app's OpenAI-compatible **connections**.
///
/// A connection is a configured endpoint (name + base URL + credential), not a choice. Every
/// configured connection is live at once and contributes its models to the shared model picker;
/// picking a model is what selects the endpoint a request routes to. So this sheet only ever
/// *configures* — it has no "use this one" affordance, deliberately.
///
/// Secrets never enter the registry: `keyValues` is the in-memory staging map keyed by connection id,
/// committed to the Keychain by the panel's Save & Apply like every other edit.
struct ConnectionsSheet: View {
    @Binding var registry: KeysRegistry
    @Binding var keyValues: [String: String]
    /// Connections whose model list is being fetched right now.
    var discovering: Set<String>
    /// Re-discover a connection's models after its endpoint or credential changes.
    var discover: (String) -> Void
    /// Selections may dangle once a connection is removed or repointed.
    var onChanged: () -> Void
    var dismiss: () -> Void

    private enum Editor: Equatable {
        case none
        case adding
        case editing(String)
    }

    @State private var editor: Editor = .none
    @State private var name = ""
    @State private var url = ""
    @State private var secret = ""
    @State private var requiresKey = true
    @State private var removing: RegisteredKey?

    var body: some View {
        VStack(spacing: 0) {
            switch editor {
            case .none: connectionList
            case .adding, .editing: connectionForm
            }
        }
        .frame(width: 460)
    }

    // MARK: List

    private var connectionList: some View {
        VStack(spacing: 0) {
            header(title: "Connections",
                   subtitle: "All configured endpoints contribute models to the model picker.",
                   showsClose: true)

            if registry.entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No connections yet")
                        .font(SettingsFont.label).foregroundStyle(.secondary)
                    Text("Add one to discover the models it serves.")
                        .font(SettingsFont.sub).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(registry.entries) { entry in
                            connectionRow(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Button { beginAdding() } label: { Label("Add connection", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 12)
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil },
                                                 set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let entry = removing { remove(entry) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its models leave the model picker. Anything currently using one falls back to "
                 + "another available model.")
        }
    }

    private func connectionRow(_ entry: RegisteredKey) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(SettingsFont.label)
                Text(subtitle(for: entry))
                    .font(SettingsFont.sub).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Edit") { beginEditing(entry) }
                .buttonStyle(.bordered)
            Button("Remove") { removing = entry }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, SettingsMetrics.rowPaddingH)
        .padding(.vertical, 11)
    }

    /// "<host path> · N models" — the two facts that say whether a connection is pulling its weight.
    private func subtitle(for entry: RegisteredKey) -> String {
        if discovering.contains(entry.id) { return "\(entry.baseURL) · discovering models…" }
        let count = entry.models.count
        let models = count == 0 ? "no models yet" : "\(count) model\(count == 1 ? "" : "s")"
        return "\(entry.baseURL) · \(models)"
    }

    // MARK: Add / edit form

    private var connectionForm: some View {
        VStack(spacing: 0) {
            header(title: editor == .adding ? "Add connection" : "Edit connection",
                   subtitle: "Configure the endpoint and credentials for this connection.",
                   showsClose: false)

            VStack(spacing: 0) {
                SettingsRow("Name") {
                    TextField("", text: $name, prompt: Text("e.g. Google, Groq, Work AI"))
                        .textFieldStyle(.roundedBorder)
                        .settingsFieldWidth()
                }
                SettingsRow("Base URL") {
                    TextField("", text: $url, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .settingsFieldWidth()
                        .onChange(of: url) { _, new in
                            // A loopback endpoint needs no credential; only guess for a new one, so
                            // we never overrule a choice already made on an existing connection.
                            if editor == .adding { requiresKey = !KeysRegistry.isLocalURL(new) }
                        }
                }
                SettingsRow("Authentication") {
                    Picker("", selection: $requiresKey) {
                        Text("API key").tag(true)
                        Text("None").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if requiresKey {
                    SettingsRow("API Key", caption: "Stored in your Mac's Keychain and shared by "
                                + "every model routed through this connection.") {
                        SettingsKeyField(text: $secret, placeholder: "Paste your API key")
                            .settingsFieldWidth()
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { editor = .none }
                    .buttonStyle(.bordered)
                Button(editor == .adding ? "Add connection" : "Save") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 12)
        }
    }

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Chrome

    private func header(title: String, subtitle: String, showsClose: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(SettingsFont.sub).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsClose {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.top, 16)
            .padding(.bottom, 13)

            Divider()
        }
    }

    // MARK: Mutations

    private func beginAdding() {
        name = ""; url = ""; secret = ""; requiresKey = true
        editor = .adding
    }

    private func beginEditing(_ entry: RegisteredKey) {
        name = entry.name
        url = entry.baseURL
        requiresKey = !entry.keyNotRequired
        secret = keyValues[entry.id] ?? ""
        editor = .editing(entry.id)
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }

        if case .editing(let id) = editor,
           let index = registry.entries.firstIndex(where: { $0.id == id }) {
            // The id survives an edit, so the Keychain account and every model selection pointing at
            // this connection stay valid through a rename or a rotated key.
            let endpointChanged = registry.entries[index].baseURL != trimmedURL
            let secretChanged = requiresKey && keyValues[id] != secret
            registry.entries[index].name = trimmedName
            registry.entries[index].baseURL = trimmedURL
            registry.entries[index].keyNotRequired = !requiresKey
            keyValues[id] = requiresKey ? secret : ""
            editor = .none
            onChanged()
            if endpointChanged || secretChanged { discover(id) }
            return
        }

        let entry = RegisteredKey(name: trimmedName, baseURL: trimmedURL,
                                  keyNotRequired: !requiresKey, enabled: true)
        registry.entries.append(entry)
        keyValues[entry.id] = requiresKey ? secret : ""
        editor = .none
        onChanged()
        discover(entry.id)
    }

    private func remove(_ entry: RegisteredKey) {
        registry.entries.removeAll { $0.id == entry.id }
        keyValues[entry.id] = nil
        onChanged()
    }
}
