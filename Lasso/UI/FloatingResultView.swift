import SwiftUI

/// Floating card that renders an action's result (text, streamed AI, or a custom view) outside the
/// freeze overlay. Used for Summarize / Ask AI / Pick color / single-shot translate — the freeze
/// drops after you pick the action and the result floats here, persisting until ✕ / Esc.
struct FloatingResultView: View {
    let title: String
    let result: ActionResult
    /// A package's name (and host), shown in the footer before the model, for package commands.
    var attribution: String?

    @AppStorage("ui.resultTextScale") private var textScale = 1.0
    @State private var streamed = ""
    @Environment(\.cardLifetime) private var lifetime
    @State private var isStreaming = false
    @State private var streamError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if isStreaming { ProgressView().controlSize(.small) }
                Spacer()
                if showsTextControls { TextScaleControls(scale: $textScale) }
                if let copyText, !copyText.isEmpty {
                    Button { Pasteboard.copy(copyText) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(IconButtonStyle()).help("Copy")
                }
                Button { FloatingPanelController.shared.close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Close")
            }

            content

            if case .stream = result, !IntelligenceCoordinator.shared.lastProviderName.isEmpty {
                Divider()
                Label([attribution, IntelligenceCoordinator.shared.lastProviderName,
                       IntelligenceCoordinator.shared.lastProviderLocationNote].compactMap { $0 }.joined(separator: " · "),
                      systemImage: IntelligenceCoordinator.shared.lastProviderIcon)
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let attribution {
                Divider()
                Label(attribution, systemImage: "shippingbox").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 460)
        .liquidGlassPanel()
        // Read inside the view's own task: SwiftUI cancels it when the card goes away (closing it drops
        // the content), which ends the stream and the model call behind it.
        .task { await streamIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .text(let text):
            scrollText(text)
        case .stream:
            if let streamError {
                Label(streamError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                scrollText(streamed.isEmpty && isStreaming ? "…" : streamed)
            }
        case .custom(let view):
            view
        default:
            EmptyView()
        }
    }

    private func scrollText(_ text: String) -> some View {
        ScrollView {
            MarkdownView(text: text, fontSize: resultTextBaseSize * textScale)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60, maxHeight: 340)
        .padding(12)
        .glassWell()
    }

    private var showsTextControls: Bool {
        switch result {
        case .text, .stream: true
        default: false
        }
    }

    private var copyText: String? {
        switch result {
        case .text(let t): t
        case .stream: streamed
        default: nil
        }
    }

    private func streamIfNeeded() async {
        guard case .stream(let stream) = result else { return }
        isStreaming = true
        // Read in a task the card owns: closing the card ends it (`CardLifetime`), and so does SwiftUI
        // cancelling this view's task.
        let reader = Task { @MainActor in
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    streamed += delta
                }
            } catch {
                if !Task.isCancelled { streamError = error.localizedDescription }
            }
            isStreaming = false
        }
        lifetime?.adopt(reader)
        await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
    }
}
