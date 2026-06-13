import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// Drives the Chat panel: a persistent, multi-turn conversation against the active Text engine.
/// Independent of the capture session — opened with its own shortcut (⌥⌘A) — but can be *seeded* from
/// a capture via "Continue in chat".
///
/// Image input is smart-routed: if the active text model is itself multimodal the image is sent
/// natively (best fidelity); otherwise it's described via the configured vision provider and the
/// description is folded into the turn — so image chat works even on Apple Intelligence / text-only
/// cloud models.
@MainActor
@Observable
final class ChatController {
    static let shared = ChatController()
    private let intelligence = IntelligenceCoordinator.shared

    /// Visible conversation (user + assistant bubbles).
    private(set) var messages: [ChatMessage] = []
    /// Composer text.
    var input = ""
    /// Image attached in the composer but not yet sent (rendered as a thumbnail chip).
    private(set) var pendingImage: CGImage?
    /// Text carried in from a capture ("Continue in chat"), shown as a removable context chip.
    private(set) var seededContext: String?

    private(set) var isStreaming = false
    /// True once the context budget started dropping older turns (shown as a subtle note).
    private(set) var trimmedNotice = false
    /// Whether attaching an image can do anything useful right now (native vision or a vision provider).
    private(set) var imageInputAvailable = false

    private var streamTask: Task<Void, Never>?

    private init() {}

    private static let systemPrompt = """
    You are Lasso's assistant — a helpful, concise chat companion living in the user's menu bar. \
    Answer directly. Use Markdown for structure when it helps.

    Always make a genuine attempt to help. Do NOT refuse or tell the user to describe their own image \
    — they can see it, and you are given an automatic description to work from. Some turns include an \
    automatic description of an attached image, produced by a separate vision model (NOT written by \
    the user) — use it as your eyes. Never say "the description you gave" or credit that description \
    to the user.

    Give a substantive best answer from what you have. If a detail is genuinely ambiguous or missing, \
    you may briefly note the uncertainty, but still provide your best interpretation rather than \
    declining. When asked to identify a person you can't name, describe who and what is visible and \
    the likely context instead of refusing. Don't invent specifics you have no basis for.
    """

    /// Rough character budget for the conversation sent to the model. Local models have unknown,
    /// often small, context windows — keep recent turns and drop the oldest beyond this.
    private static let maxContextChars = 12_000

    // MARK: - Composer state

    func attach(_ image: CGImage) { pendingImage = image }
    func clearAttachment() { pendingImage = nil }
    func clearSeededContext() { seededContext = nil }

    /// Attach an image only when a vision backend can actually use it (otherwise no-op).
    @discardableResult
    func attachIfPossible(_ image: CGImage) -> Bool {
        guard imageInputAvailable else { return false }
        attach(image)
        return true
    }

    /// Try to pull an image off the general pasteboard and attach it (for ⌘V). Returns true if an
    /// image was found and attached — the caller can then consume the paste so it doesn't also land
    /// as text.
    @discardableResult
    func pasteImageFromClipboard() -> Bool {
        guard imageInputAvailable, let image = Self.clipboardImage() else { return false }
        attach(image)
        return true
    }

    /// Read an image from the general pasteboard: raw image data, or a copied image file URL.
    static func clipboardImage() -> CGImage? {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = images.first,
           let cg = first.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cg
        }
        return nil
    }

    var hasMessages: Bool { !messages.isEmpty }
    /// Whether there's anything to clear (drives the "New chat" button's enabled state).
    var canClear: Bool {
        !messages.isEmpty || !input.isEmpty || pendingImage != nil || seededContext != nil
    }

    /// Seed a fresh chat from a capture: pre-fill the selection's text and/or image as context.
    func seed(text: String?, image: CGImage?) {
        newChat()
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        seededContext = (trimmed?.isEmpty == false) ? trimmed : nil
        pendingImage = image
    }

    func newChat() {
        streamTask?.cancel()
        streamTask = nil
        messages.removeAll()
        input = ""
        pendingImage = nil
        seededContext = nil
        isStreaming = false
        trimmedNotice = false
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].isStreaming = false
            if messages[last].text.isEmpty { messages[last].text = "(Stopped.)" }
        }
    }

    /// Refresh whether image attachment is useful (called when the panel opens / engine changes).
    func refreshCapabilities() async {
        await intelligence.refreshVisionAvailability()
        let nativeVision = await intelligence.textModelSupportsVision()
        imageInputAvailable = intelligence.visionAvailable || nativeVision
    }

    // MARK: - Sending

    func send() {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || pendingImage != nil else { return }
        guard !isStreaming else { return }

        let image = pendingImage
        let context = seededContext

        let userMessage = ChatMessage(role: .user, text: typed.isEmpty ? "Look at this image" : typed,
                                      image: image)
        messages.append(userMessage)
        let userID = userMessage.id
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id

        input = ""
        pendingImage = nil
        seededContext = nil
        isStreaming = true

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runTurn(typed: typed, image: image, context: context,
                                userID: userID, assistantID: assistantID)
        }
    }

    private func runTurn(typed: String, image: CGImage?, context: String?,
                         userID: UUID, assistantID: UUID) async {
        var userText = typed
        if let context, !context.isEmpty {
            userText = "Context — text I selected on screen:\n\(context)\n\n"
                + (typed.isEmpty ? "What does this say / mean?" : typed)
        }
        var imageBase64: String?

        if let image {
            if await intelligence.textModelSupportsVision() {
                imageBase64 = ImageEncoder.jpegBase64(image)
            }
            if imageBase64 == nil {
                // Text-only model: describe the image via the vision provider and fold it in.
                var described: String?
                if let vision = await intelligence.activeVisionProvider() {
                    let prompt = typed.isEmpty
                        ? "Describe this image in detail."
                        : "Describe this image in detail to help answer: \(typed)"
                    described = try? await vision.describe(image, prompt: prompt)
                }
                if let described, !described.isEmpty {
                    userText = """
                    [I attached an image. A separate vision model produced this description of it — \
                    it may be incomplete or wrong, so treat it cautiously and don't attribute it to me:]
                    \(described)

                    \(typed.isEmpty ? "What is this?" : typed)
                    """
                } else {
                    // No backend could read the image — don't send a blank/garbage turn.
                    finishError(assistantID,
                        "I couldn't read that image — your current model can't see images. Set an "
                        + "Image provider under Settings ▸ Intelligence ▸ Image (a local Ollama vision "
                        + "model, or a multimodal cloud model) to chat about images.")
                    return
                }
            }
        }

        // Persist what was actually sent so the description / image carries into follow-up turns.
        update(userID) { $0.promptText = userText; $0.imageBase64 = imageBase64 }

        let turns = buildTurns(newUserText: userText, imageBase64: imageBase64)
        if Task.isCancelled { return }

        do {
            for try await delta in intelligence.respond(messages: turns) {
                if Task.isCancelled { return }
                update(assistantID) { $0.text += delta }
            }
        } catch {
            finishError(assistantID, error.localizedDescription)
            return
        }
        finishStreaming(assistantID)
    }

    /// Build the trimmed `[ChatTurn]` to send: system + prior history + the new (folded) user turn.
    private func buildTurns(newUserText: String, imageBase64: String?) -> [ChatTurn] {
        var turns: [ChatTurn] = [.init(role: .system, text: Self.systemPrompt)]
        // Exclude the just-appended user-display and assistant-placeholder messages. Use each
        // message's persisted `promptText` (with any folded image description) so context carries.
        for m in messages.dropLast(2) {
            turns.append(.init(role: m.role == .user ? .user : .assistant,
                               text: m.promptText ?? m.text, imageBase64: m.imageBase64))
        }
        turns.append(.init(role: .user, text: newUserText, imageBase64: imageBase64))
        return trim(turns)
    }

    /// Keep the system turn + most recent turns under the char budget, dropping the oldest.
    private func trim(_ turns: [ChatTurn]) -> [ChatTurn] {
        func total(_ t: [ChatTurn]) -> Int { t.reduce(0) { $0 + $1.text.count } }
        guard total(turns) > Self.maxContextChars else { trimmedNotice = false; return turns }
        let system = turns.first
        var rest = Array(turns.dropFirst())
        while rest.count > 1, total((system.map { [$0] } ?? []) + rest) > Self.maxContextChars {
            rest.removeFirst()
        }
        trimmedNotice = true
        return (system.map { [$0] } ?? []) + rest
    }

    // MARK: - Message mutation helpers

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { mutate(&messages[i]) }
    }

    private func finishStreaming(_ id: UUID) {
        update(id) {
            $0.isStreaming = false
            if $0.text.isEmpty { $0.text = "(No response.)" }
        }
        isStreaming = false
    }

    private func finishError(_ id: UUID, _ message: String) {
        update(id) { $0.text = message; $0.isError = true; $0.isStreaming = false }
        isStreaming = false
    }
}
