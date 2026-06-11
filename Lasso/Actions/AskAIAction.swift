import SwiftUI
import CoreGraphics

/// Free-form "ask about this" against the active intelligence provider. Presents a small input +
/// streamed answer inline (Spec §8). World-knowledge questions are best served by the Ollama
/// provider (`qwen3:4b`); on-device handles transform/explain tasks. When the selection has no
/// readable text, the question is grounded in a local vision-model description of the image.
struct AskAIAction: CaptureAction {
    let intelligence: IntelligenceCoordinator

    let id = "ai.ask"
    let title = "Ask AI"
    let systemImage = "bubble.left.and.text.bubble.right"
    let relevancePriority = 40

    func isRelevant(to ctx: CaptureContext) -> Bool { true }
    // Text selections answer from the text model; only an image with no readable text needs vision.
    func needsVision(for ctx: CaptureContext) -> Bool { (ctx.ocrText ?? "").isEmpty }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        .custom(AnyView(AskAIView(intelligence: intelligence, image: ctx.image, ocrText: ctx.ocrText)))
    }
}

private struct AskAIView: View {
    let intelligence: IntelligenceCoordinator
    let image: CGImage
    let ocrText: String?

    @State private var question = ""
    @State private var answer = ""
    @State private var status = ""
    @State private var isStreaming = false
    @State private var task: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    @AppStorage("ui.resultTextScale") private var textScale = 1.0

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
                HStack {
                    Spacer()
                    TextScaleControls(scale: $textScale)
                }
                ScrollView {
                    Group {
                        if answer.isEmpty {
                            Text(status.isEmpty ? "…" : status)
                                .font(.system(size: resultTextBaseSize * textScale))
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: answer, fontSize: resultTextBaseSize * textScale)
                        }
                    }
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
                Label("\(intelligence.lastProviderName) · \(intelligence.lastProviderLocationNote)",
                      systemImage: intelligence.lastProviderIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        status = ""
        isStreaming = true
        task = Task {
            // Safeguard: the on-device model botches free-form Markdown tables. If the user asks
            // for a table while Apple Intelligence is active, use guided generation instead of
            // wasting a broken streamed attempt. Ollama handles tables fine via the normal path.
            if IntelligenceCoordinator.looksLikeTableRequest(q),
               await intelligence.activeProvider().isAppleOnDevice {
                do {
                    answer = try await intelligence.onDeviceTableMarkdown(prompt: q, context: ocrText)
                    isStreaming = false
                    return
                } catch {
                    // Fall through to normal streaming if guided generation fails.
                    answer = ""
                }
            }

            // Pick context: real on-screen text, or — when there's little/no text — a local vision
            // description of the image so the answer is grounded in what's actually selected.
            var context = ocrText
            let letters = (ocrText ?? "").filter(\.isLetter).count
            if letters < 15 {
                if let vision = await intelligence.activeVisionProvider() {
                    status = "Looking at the image…"
                    let described = try? await vision.describe(
                        image, prompt: "Describe this image in detail to help answer: \(q)")
                    status = ""
                    if let described, !described.isEmpty { context = described }
                } else if (ocrText ?? "").isEmpty {
                    answer = "There's no readable text here and no vision model is available. "
                        + "Pick a multimodal cloud model, or pull a local one "
                        + "(e.g. `ollama pull qwen3-vl:2b`), to ask about images."
                    isStreaming = false
                    return
                }
            }

            do {
                for try await delta in intelligence.respond(prompt: q, context: context) {
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
