import SwiftUI

/// Floating card that renders an action's result (text, streamed AI, or a custom view) outside the
/// freeze overlay. Used for Summarize / Ask AI / Pick color / single-shot translate — the freeze
/// drops after you pick the action and the result floats here, persisting until ✕ / Esc.
struct FloatingResultView: View {
    let title: String
    let result: ActionResult

    @AppStorage("ui.resultTextScale") private var textScale = 1.0
    @State private var streamed = ""
    @State private var isStreaming = false
    @State private var streamError: String?
    @State private var task: Task<Void, Never>?

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
                Label("\(IntelligenceCoordinator.shared.lastProviderName) · \(IntelligenceCoordinator.shared.lastProviderLocationNote)",
                      systemImage: IntelligenceCoordinator.shared.lastProviderIcon)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .task { startStreamingIfNeeded() }
        .onDisappear { task?.cancel() }
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

    private func startStreamingIfNeeded() {
        guard case .stream(let stream) = result else { return }
        isStreaming = true
        task = Task {
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    streamed += delta
                }
            } catch {
                streamError = error.localizedDescription
            }
            isStreaming = false
        }
    }
}
