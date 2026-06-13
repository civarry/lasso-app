import SwiftUI

/// Reusable MLX model selector + downloader/manager: a Menu of suggested models (downloaded first,
/// with state icons) + Custom…, an inline download row (size → progress + cancel → "On this Mac" +
/// red Remove with confirmation). Self-contained state, driven by a `modelID` binding. Used for the
/// Image (vision) MLX model.
struct MLXModelManager: View {
    @Binding var modelID: String
    let suggestions: [(name: String, id: String)]
    let defaultID: String
    var localOnly: Bool

    private enum Phase: Equatable { case idle, downloading, failed(String) }
    @State private var phase: Phase = .idle
    @State private var remoteSize: Int64?
    @State private var sizeLoading = false
    @State private var progress: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var sizeTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var installed: [MLXCache.Entry] = []
    @State private var removeConfirm = false

    private var suggestionIDs: Set<String> { Set(suggestions.map(\.id)) }
    private var isCustom: Bool { !suggestionIDs.contains(modelID) }
    private var downloadedSuggestions: [(name: String, id: String)] {
        suggestions.filter { MLXProvider.isDownloaded($0.id) }
    }
    private var availableSuggestions: [(name: String, id: String)] {
        suggestions.filter { !MLXProvider.isDownloaded($0.id) }
    }
    private var currentEntry: MLXCache.Entry? {
        installed.first { MLXProvider.normalizedID($0.repoID) == MLXProvider.normalizedID(modelID) }
    }
    private var menuLabel: String {
        if let s = suggestions.first(where: { $0.id == modelID }) { return s.name }
        return modelID.isEmpty ? "Custom…" : modelID
    }

    var body: some View {
        LabeledContent("Model") {
            Menu {
                ForEach(downloadedSuggestions, id: \.id) { menuItem($0) }
                if !downloadedSuggestions.isEmpty, !availableSuggestions.isEmpty { Divider() }
                ForEach(availableSuggestions, id: \.id) { menuItem($0) }
                Divider()
                Button("Custom…") { if suggestionIDs.contains(modelID) { modelID = "" } }
            } label: {
                Text(menuLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .onAppear { refreshInstalled(); refreshSize() }
        .onChange(of: modelID) { phase = .idle; refreshSize() }

        if isCustom {
            TextField("Model id", text: $modelID, prompt: Text(defaultID))
        }

        downloadRow
    }

    @ViewBuilder
    private func menuItem(_ suggestion: (name: String, id: String)) -> some View {
        Button { modelID = suggestion.id } label: {
            Label(suggestion.name,
                  systemImage: MLXProvider.isDownloaded(suggestion.id)
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        if phase == .downloading {
            HStack(spacing: 8) {
                if let total = remoteSize, total > 0 {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))% · \(byteString(downloadedBytes)) / \(byteString(total))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { cancel() }.controlSize(.small)
                Spacer()
            }
        } else if case .failed(let message) = phase {
            HStack(spacing: 8) {
                Button { download() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                Spacer()
            }
        } else if !MLXProvider.isDownloaded(modelID) {
            HStack(spacing: 8) {
                Button { download() } label: { Label(downloadLabel, systemImage: "arrow.down.circle") }
                    .disabled(localOnly)
                if localOnly {
                    Text("Local-only mode blocks downloads").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else {
            HStack(spacing: 8) {
                Label("On this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Spacer()
                if let entry = currentEntry {
                    Button { removeConfirm = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                        .help("Remove this model")
                        .confirmationDialog("Remove \(entry.repoID)?",
                                            isPresented: $removeConfirm, titleVisibility: .visible) {
                            Button("Remove", role: .destructive) { remove(entry) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes the downloaded files (\(byteString(entry.sizeBytes))). "
                                + "You can download it again later.")
                        }
                }
            }
        }
    }

    private var downloadLabel: String {
        if sizeLoading { return "Download model · checking size…" }
        if let size = remoteSize { return "Download model · \(byteString(size))" }
        return "Download model"
    }

    // MARK: - Actions

    private func refreshInstalled() { installed = MLXCache.installed() }

    private func refreshSize() {
        sizeTask?.cancel()
        remoteSize = nil
        sizeLoading = false
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localOnly, !id.isEmpty, !MLXProvider.isDownloaded(id) else { return }
        sizeLoading = true
        sizeTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let size = await MLXCache.remoteSizeBytes(for: id)
            if Task.isCancelled { return }
            remoteSize = size
            sizeLoading = false
        }
    }

    private func download() {
        let id = modelID
        phase = .downloading
        progress = 0
        downloadedBytes = 0
        let total = remoteSize
        let dir = MLXCache.directory(for: id)

        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                let onDisk = await Task.detached { MLXCache.size(of: dir) }.value
                downloadedBytes = onDisk
                if let total, total > 0 { progress = min(1, Double(onDisk) / Double(total)) }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        downloadTask?.cancel()
        downloadTask = Task {
            do {
                try await MLXProvider.ensureDownloaded(id)
                if Task.isCancelled { return }
                progress = 1
                phase = .idle
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    phase = .failed(error.localizedDescription)
                }
            }
            pollTask?.cancel()
            refreshInstalled()
        }
    }

    private func cancel() {
        downloadTask?.cancel()
        pollTask?.cancel()
        phase = .idle
        progress = 0
        downloadedBytes = 0
        refreshInstalled()
    }

    private func remove(_ entry: MLXCache.Entry) {
        Task {
            try? await MLXProvider.remove(entry)
            phase = .idle
            refreshInstalled()
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
