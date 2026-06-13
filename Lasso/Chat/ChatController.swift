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
    /// Whether any web / reverse-image connector is configured (drives the globe toggle's visibility).
    private(set) var webConnectorsAvailable = false
    /// User-facing toggle: ground answers with web/connector evidence. Defaults on when available.
    var webSearchOn = true

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

    /// Factual description of Lasso, injected only when the user asks "What can you do?" (the starter
    /// chip) so the model explains the *real* app instead of guessing. Not a standing system prompt.
    static let lassoCapabilities = """
    Context about Lasso — the macOS menu-bar app you are the assistant inside (answer questions about \
    what Lasso can do using only this):
    • Capture: press ⌥⌘Space to select any region of the screen. On a selection you can Copy text \
    (OCR), Translate it (including in-place overlay), Summarize, Ask AI about it, Identify what it is, \
    open detected QR/barcodes, pick a color, copy or save the image, or “Continue in chat”. Detected \
    links, phone numbers, emails and dates appear as quick action chips.
    • Chat (this panel): press ⌥⌘A. Multi-turn conversation, attach images (button, ⌘V paste, or \
    drag-and-drop), and optional web grounding.
    • Models: choose a Text engine and a separate Image (vision) engine independently — Apple \
    Intelligence, local Ollama, local MLX, or a cloud model (OpenAI-compatible / Anthropic). \
    On-device and private by default; cloud is opt-in; a Local-only mode blocks all non-local calls.
    • Connectors (optional): Web search (Wikipedia / DuckDuckGo / Reddit), Tavily, SerpApi, and \
    Google Vision reverse-image — these ground answers with real sources.
    Be concise and accurate; don’t invent features not listed here.
    """

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
        webConnectorsAvailable = Self.computeWebAvailable()
    }

    /// Any web or reverse-image connector active (respecting local-only mode).
    static func computeWebAvailable() -> Bool {
        Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive() || Connectors.googleVision.isActive()
    }

    // MARK: - Sending

    /// Send a message. `text` overrides the composer (used by the suggestion chips); `extraContext`
    /// is a one-shot context folded into *only this* turn (e.g. Lasso's feature list for the
    /// "What can you do?" chip) — it never becomes a standing system prompt, so normal chats stay clean.
    func send(text: String? = nil, extraContext: String? = nil, webSearch: Bool? = nil) {
        if let text { input = text }
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

        // Whether to ground this turn with connectors. A chip can force it off (e.g. "What can you
        // do?", already grounded by the injected Lasso context — a web search there is just noise).
        let ground = (webSearch ?? webSearchOn) && webConnectorsAvailable

        Log.chat.notice("send: typedChars=\(typed.count, privacy: .public) hasImage=\(image != nil, privacy: .public) ground=\(ground, privacy: .public) history=\(self.messages.count, privacy: .public)")
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runTurn(typed: typed, image: image, context: context, appContext: extraContext,
                                ground: ground, userID: userID, assistantID: assistantID)
        }
    }

    private func runTurn(typed: String, image: CGImage?, context: String?, appContext: String?,
                         ground: Bool, userID: UUID, assistantID: UUID) async {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        Log.chat.notice("runTurn ▶ begin")

        var userText = typed
        if let context, !context.isEmpty {
            userText = "Context — text I selected on screen:\n\(context)\n\n"
                + (typed.isEmpty ? "What does this say / mean?" : typed)
            Log.chat.notice("runTurn · folded seeded context (\(context.count, privacy: .public) chars)")
        }
        // One-shot app context (e.g. Lasso capabilities) — prepended for this turn only.
        if let appContext, !appContext.isEmpty {
            userText = "\(appContext)\n\n\(userText)"
            Log.chat.notice("runTurn · folded app context (\(appContext.count, privacy: .public) chars)")
        }
        var imageBase64: String?

        // Kick off connector grounding now so it overlaps the image describe — they're independent
        // (the web query uses the reverse-image guess / the user's text, not the description). The
        // box lets the CGImage cross the async-let task boundary (it's immutable, safe to read).
        let boxed = image.map { UncheckedImage(cg: $0) }
        async let evidenceResult = gatherEvidence(typed: typed, boxed: boxed, enabled: ground)

        if let image {
            Log.chat.notice("runTurn · image present — checking native vision (+\(ms(), privacy: .public)ms)")
            let native = await intelligence.textModelSupportsVision()
            Log.chat.notice("runTurn · textModelSupportsVision=\(native, privacy: .public) (+\(ms(), privacy: .public)ms)")
            if native {
                imageBase64 = ImageEncoder.jpegBase64(image)
                Log.chat.notice("runTurn · native encode done, base64=\(imageBase64?.count ?? 0, privacy: .public) chars (+\(ms(), privacy: .public)ms)")
            }
            if imageBase64 == nil {
                // Text-only model: describe the image via the vision provider and fold it in.
                Log.chat.notice("runTurn · resolving vision provider for describe (+\(ms(), privacy: .public)ms)")
                let vision = await intelligence.activeVisionProvider()
                let label = intelligence.imageEngineLabel
                Log.chat.notice("runTurn · vision provider=\(vision == nil ? "nil" : "\(type(of: vision!))", privacy: .public) (+\(ms(), privacy: .public)ms)")
                var described: String?
                var describeError: Error?
                if let vision {
                    let stepID = addStep(assistantID, icon: "eye", text: "Looking at the image · \(label)")
                    let prompt = typed.isEmpty
                        ? "Describe this image in detail."
                        : "Describe this image in detail to help answer: \(typed)"
                    Log.chat.notice("runTurn · describe START (+\(ms(), privacy: .public)ms)")
                    do {
                        described = try await vision.describe(image, prompt: prompt)
                        completeStep(assistantID, stepID, text: "Looked at the image · \(label)")
                        Log.chat.notice("runTurn · describe DONE len=\(described?.count ?? 0, privacy: .public) (+\(ms(), privacy: .public)ms)")
                    } catch {
                        describeError = error
                        completeStep(assistantID, stepID, text: "Couldn't read the image · \(label)")
                        Log.chat.error("runTurn · describe FAILED: \(error.localizedDescription, privacy: .public) (+\(ms(), privacy: .public)ms)")
                    }
                }
                if let described, !described.isEmpty {
                    userText = """
                    [I attached an image. A separate vision model produced this description of it — \
                    it may be incomplete or wrong, so treat it cautiously and don't attribute it to me:]
                    \(described)

                    \(typed.isEmpty ? "What is this?" : typed)
                    """
                } else if vision == nil {
                    finishError(assistantID,
                        "No image model is set. Choose one under Settings ▸ Intelligence ▸ Image "
                        + "(a local Ollama vision model, or a multimodal cloud model) to chat about images.")
                    return
                } else if let describeError {
                    // The image model exists but the request failed (timeout / rate-limit / offline).
                    finishError(assistantID,
                        "The image model (\(label)) couldn't read this image: "
                        + "\(describeError.localizedDescription) It may be slow, rate-limited, or "
                        + "offline — try again, or switch image models in Settings ▸ Intelligence ▸ Image.")
                    return
                } else {
                    finishError(assistantID,
                        "The image model (\(label)) returned no description. Try again, or switch "
                        + "models in Settings ▸ Intelligence ▸ Image.")
                    return
                }
            }
        }

        // Fold in the connector evidence started above (waits only if it's still running).
        let searchStepID: UUID? = ground
            ? addStep(assistantID, icon: "globe", text: "Searching the web…") : nil
        if ground {
            Log.chat.notice("runTurn · awaiting web evidence (+\(ms(), privacy: .public)ms)")
        }
        if let evidence = await evidenceResult {
            userText = appendEvidence(userText, evidence)
            let hits = Array(evidence.hits.prefix(6))
            update(assistantID) { $0.sources = hits }
            if let searchStepID {
                var text = "Found \(hits.count) source\(hits.count == 1 ? "" : "s")"
                if let guess = evidence.bestGuess, !guess.isEmpty { text = "Identified “\(guess)” · " + text }
                completeStep(assistantID, searchStepID, text: text, links: hits)
            }
            Log.chat.notice("runTurn · evidence: guess=\(evidence.bestGuess ?? "-", privacy: .public) hits=\(hits.count, privacy: .public) (+\(ms(), privacy: .public)ms)")
        } else if let searchStepID {
            completeStep(assistantID, searchStepID, text: "No web results")
        }

        // Persist what was actually sent so the description / image carries into follow-up turns.
        update(userID) { $0.promptText = userText; $0.imageBase64 = imageBase64 }

        let textLabel = intelligence.textEngineLabel
        let answerStepID = addStep(assistantID, icon: "sparkles", text: "Answering · \(textLabel)")
        let turns = buildTurns(newUserText: userText, imageBase64: imageBase64)
        let totalChars = turns.reduce(0) { $0 + $1.text.count }
        Log.chat.notice("runTurn · built \(turns.count, privacy: .public) turns, \(totalChars, privacy: .public) chars — stream START (+\(ms(), privacy: .public)ms)")
        if Task.isCancelled { Log.chat.notice("runTurn · cancelled before stream"); return }

        var deltas = 0
        var chars = 0
        var firstTokenMs = -1
        var raw = ""              // full stream, so we can split <think> reasoning from the answer
        var thinkStart: Date?
        do {
            for try await delta in intelligence.respond(messages: turns) {
                if Task.isCancelled { Log.chat.notice("runTurn · cancelled mid-stream after \(chars, privacy: .public) chars"); return }
                if firstTokenMs < 0 { firstTokenMs = ms(); Log.chat.notice("runTurn · first token (+\(firstTokenMs, privacy: .public)ms)") }
                deltas += 1; chars += delta.count
                raw += delta
                let split = Self.splitReasoning(raw)
                if split.thinking, thinkStart == nil { thinkStart = Date() }
                let secs: Int? = (!split.thinking && !split.reasoning.isEmpty)
                    ? thinkStart.map { max(1, Int(Date().timeIntervalSince($0))) } : nil
                update(assistantID) {
                    $0.reasoning = split.reasoning
                    $0.text = split.answer
                    if let secs, $0.reasoningSeconds == nil { $0.reasoningSeconds = secs }
                }
            }
            completeStep(assistantID, answerStepID, text: "Answered · \(textLabel)")
        } catch {
            Log.chat.error("runTurn · stream ERROR after \(chars, privacy: .public) chars: \(error.localizedDescription, privacy: .public) (+\(ms(), privacy: .public)ms)")
            finishError(assistantID, error.localizedDescription)
            return
        }
        Log.chat.notice("runTurn ✓ stream DONE deltas=\(deltas, privacy: .public) chars=\(chars, privacy: .public) (+\(ms(), privacy: .public)ms)")
        finishStreaming(assistantID)
    }

    // MARK: - Web / connector grounding

    /// Gather evidence from the active connectors: reverse-image (Google Vision) for image turns to
    /// get a best-guess identity, then a text web lookup (Wikipedia / DuckDuckGo / Tavily / SerpApi)
    /// on the strongest query. Returns nil when nothing usable was found.
    private func gatherEvidence(typed: String, boxed: UncheckedImage?, enabled: Bool) async -> Evidence? {
        guard enabled, !PrivacyMode.localOnly else { return nil }
        let image = boxed?.cg
        let webActive = Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive()
        let reverseActive = image != nil && Connectors.googleVision.isActive()
        guard webActive || reverseActive else { return nil }

        var evidence = Evidence()
        if reverseActive, let image {
            evidence.merge(await GoogleVisionSource().gather(image: image, query: typed, ocrText: nil))
        }
        if webActive {
            let query = Self.searchQuery(bestGuess: evidence.bestGuess, entity: evidence.entities.first,
                                         typed: typed, description: nil)
            if !query.isEmpty {
                let result = await WebSourcesProvider().lookup(query)
                evidence.merge(Evidence(abstract: result.abstract, hits: result.hits))
            }
        }
        return evidence.isEmpty ? nil : evidence
    }

    /// Best query for text web search: a specific reverse-image guess wins, else the user's words,
    /// else a recognized entity, else key terms from the image description.
    private static func searchQuery(bestGuess: String?, entity: String?,
                                    typed: String, description: String?) -> String {
        if let g = bestGuess, !g.isEmpty { return typed.isEmpty ? g : "\(g) \(typed)" }
        if !typed.isEmpty { return typed }
        if let e = entity, !e.isEmpty { return e }
        if let d = description, !d.isEmpty { return String(d.prefix(120)) }
        return ""
    }

    /// Fold gathered evidence into the turn as grounding context for the model.
    private func appendEvidence(_ text: String, _ evidence: Evidence) -> String {
        var lines: [String] = []
        if let g = evidence.bestGuess, !g.isEmpty {
            lines.append("Likely identification (reverse-image search): \(g)")
        }
        if !evidence.entities.isEmpty {
            lines.append("Related entities: \(evidence.entities.prefix(6).joined(separator: ", "))")
        }
        if let a = evidence.abstract, !a.isEmpty { lines.append("Reference summary: \(a)") }
        if !evidence.hits.isEmpty {
            let src = evidence.hits.prefix(6)
                .map { "- \($0.title)\($0.url.map { u in " (\(u.absoluteString))" } ?? "")" }
                .joined(separator: "\n")
            lines.append("Sources:\n\(src)")
        }
        guard !lines.isEmpty else { return text }
        return """
        \(text)

        [Web evidence gathered for this question — ground your answer in it and mention sources where \
        relevant; do not invent facts it doesn't support:]
        \(lines.joined(separator: "\n"))
        """
    }

    /// Build the trimmed `[ChatTurn]` to send: system + prior history + the new (folded) user turn.
    private func buildTurns(newUserText: String, imageBase64: String?) -> [ChatTurn] {
        var turns: [ChatTurn] = [.init(role: .system, text: Self.systemPrompt)]
        // Exclude the just-appended user-display and assistant-placeholder messages. Use each
        // message's persisted `promptText` (with any folded image description) so context carries.
        // Assistant thoughts are UI/debug affordances, not conversation content.
        for m in messages.dropLast(2) {
            let role: ChatTurn.Role = m.role == .user ? .user : .assistant
            let text = role == .assistant
                ? Self.stripThoughtBlocks(from: m.promptText ?? m.text)
                : (m.promptText ?? m.text)
            turns.append(.init(role: m.role == .user ? .user : .assistant,
                               text: text, imageBase64: m.imageBase64))
        }
        turns.append(.init(role: .user, text: newUserText, imageBase64: imageBase64))
        return trim(turns)
    }

    private static func stripThoughtBlocks(from text: String) -> String {
        var remaining = text
        var result = ""
        while let start = remaining.range(of: "<think>", options: [.caseInsensitive]) {
            result += remaining[..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.range(of: "</think>", options: [.caseInsensitive]) else {
                remaining = ""
                break
            }
            remaining = String(afterStart[end.upperBound...])
        }
        result += remaining
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Append an in-progress activity step to an assistant message; returns its id for completion.
    @discardableResult
    private func addStep(_ id: UUID, icon: String, text: String) -> UUID {
        let step = ActivityStep(icon: icon, text: text)
        update(id) { $0.steps.append(step) }
        return step.id
    }

    private func completeStep(_ id: UUID, _ stepID: UUID, text: String? = nil,
                             links: [WebSourcesProvider.Hit] = []) {
        update(id) { msg in
            guard let i = msg.steps.firstIndex(where: { $0.id == stepID }) else { return }
            msg.steps[i].done = true
            if let text { msg.steps[i].text = text }
            if !links.isEmpty { msg.steps[i].links = links }
        }
    }

    /// Split a model's raw stream into reasoning (inside `<think>…</think>`) and the answer. Handles
    /// the partial mid-stream state (open tag, not yet closed) so the thought streams live.
    static func splitReasoning(_ raw: String) -> (reasoning: String, answer: String, thinking: Bool) {
        guard let open = raw.range(of: "<think>", options: [.caseInsensitive]) else {
            return ("", raw, false)
        }
        let prefix = String(raw[..<open.lowerBound])
        let afterOpen = raw[open.upperBound...]
        if let close = afterOpen.range(of: "</think>", options: [.caseInsensitive]) {
            let reasoning = String(afterOpen[..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (prefix + String(afterOpen[close.upperBound...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning, answer, false)
        }
        return (String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines),
                prefix.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private func finishStreaming(_ id: UUID) {
        update(id) {
            $0.isStreaming = false
            if $0.text.isEmpty {
                $0.text = $0.reasoning.isEmpty ? "(No response.)" : "(No answer — see the thinking above.)"
            }
        }
        isStreaming = false
    }

    private func finishError(_ id: UUID, _ message: String) {
        update(id) { $0.text = message; $0.isError = true; $0.isStreaming = false }
        isStreaming = false
    }
}

/// Lets an immutable `CGImage` cross an `async let` task boundary. The pixels are never mutated after
/// capture, so concurrent reads are safe (same rationale as `CaptureContext`'s `@unchecked Sendable`).
private struct UncheckedImage: @unchecked Sendable {
    let cg: CGImage
}
