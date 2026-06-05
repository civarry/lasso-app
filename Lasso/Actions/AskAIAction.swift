import SwiftUI

/// Free-form "ask about this" against the active intelligence provider. Presents a small input +
/// streamed answer inline (Spec §8). World-knowledge questions are best served by the Ollama
/// provider (`gpt-oss:20b`); on-device handles transform/explain tasks.
struct AskAIAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.ask"
    let title = "Ask AI"
    let systemImage = "bubble.left.and.text.bubble.right"
    let relevancePriority = 40

    func isRelevant(to ctx: CaptureContext) -> Bool { true }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        .custom(AnyView(AskAIView(intelligence: intelligence, ocrText: ctx.ocrText)))
    }
}

private struct AskAIView: View {
    let intelligence: IntelligenceCoordinator
    let ocrText: String?

    @State private var question = ""
    @State private var answer = ""
    @State private var isStreaming = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Ask about this selection…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if isStreaming || !answer.isEmpty {
                ScrollView {
                    Text(answer.isEmpty ? AttributedString("…") : AttributedString.fromMarkdown(answer))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            if intelligence.lastProviderName.isEmpty {
                Text(intelligence.privacyNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("\(intelligence.lastProviderName) · on this Mac",
                      systemImage: intelligence.lastProviderIsAppleOnDevice ? "cpu" : "server.rack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 400)
        .onAppear {
            // Focus the field so the user can type immediately. Deferred so the view is in the
            // window's responder chain first.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear { task?.cancel() }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        task?.cancel()
        answer = ""
        isStreaming = true
        task = Task {
            do {
                for try await delta in intelligence.respond(prompt: q, context: ocrText) {
                    if Task.isCancelled { break }
                    answer += delta
                }
            } catch {
                answer = "Error: \(error.localizedDescription)"
            }
            isStreaming = false
        }
    }
}
