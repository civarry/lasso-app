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
    private let ocr = OCREngine()

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
    /// User-facing toggle: ground answers with web/connector evidence. Persisted across launches and
    /// **defaults off** — the user opts in by tapping the globe, and that choice sticks until changed.
    var webSearchOn: Bool {
        didSet { UserDefaults.standard.set(webSearchOn, forKey: Self.webSearchKey) }
    }
    private static let webSearchKey = "chat.webSearchOn"

    private var streamTask: Task<Void, Never>?

    // MARK: - Rolling conversation summary (long-session memory)

    /// Running, compact recap of everything that has scrolled out of the recent verbatim window.
    /// Injected by `buildTurns` so the model still "remembers" earlier context instead of losing it
    /// to a hard drop. Reset in `newChat()`. Built off the send path (see `scheduleSummaryUpdate`).
    private var rollingSummary = ""
    /// The number of overflow turns the current `rollingSummary` already covers — so an incremental
    /// update only folds in turns that aren't represented yet (cheap, and avoids re-summarizing).
    private var summarizedTurnCount = 0
    /// In-flight background summarization, cancelled on a new update or `newChat()`. Never on the
    /// user's `send` path, so it can't block a reply.
    private var summaryTask: Task<Void, Never>?
    /// The budgeted assembler — char-based, provider-agnostic. Tunable here if a model needs a
    /// tighter window later (the same pipeline serves tiny local → large cloud).
    private let contextBuilder = ChatContextBuilder()

    private init() {
        // Default off; restore the user's last choice if they ever set it.
        webSearchOn = UserDefaults.standard.object(forKey: Self.webSearchKey) as? Bool ?? false
    }

    private static let systemPrompt = """
    You are Lasso's assistant — a helpful, concise chat companion living in the user's menu bar. \
    Answer directly. Use Markdown for structure when it helps.

    This is an ongoing conversation. Greet the user at most once, only if they greet first; never open \
    a later reply with "Hello", "Hi", or "It's great to meet you". Do NOT restate your name, role, or a \
    list of what you can do unless the user explicitly asks. Each reply should answer only the user's \
    newest message — don't repeat sentences from your previous replies. If you've already introduced \
    yourself, just answer.

    Do NOT paste raw URLs or add a "Sources"/"References" list to your reply — the app already shows \
    the sources you used as separate links. Just answer naturally; weave in a source name only if it \
    reads well in a sentence.

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
    • Models: choose a Language model and a separate Image (vision) model independently — Apple \
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

    /// Open a fresh chat seeded with a prior one-shot exchange (e.g. from Ask AI), so the user can
    /// keep going with the same on-screen context. The selection text rides on the user turn's
    /// promptText so follow-ups stay grounded.
    func continueWith(question: String, answer: String, context: String?, image: CGImage?) {
        newChat()
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = ChatMessage(role: .user, text: q.isEmpty ? "About this" : q, image: image)
        if let context, !context.isEmpty {
            user.promptText = "Context — from my screen:\n\(context)\n\n\(q.isEmpty ? "About this" : q)"
        }
        messages.append(user)
        messages.append(ChatMessage(role: .assistant, text: answer))
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
        summaryTask?.cancel()
        summaryTask = nil
        rollingSummary = ""
        summarizedTurnCount = 0
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
        await refreshModels()
    }

    // MARK: - Quick model switch (header menu)

    /// Installed local Ollama text models, cached for the header menu (Ollama listing is async; the
    /// rest are read synchronously when the menu builds).
    private(set) var ollamaModels: [String] = []

    func refreshModels() async {
        ollamaModels = (await OllamaModels.installed())
            .filter { !OllamaModels.isEmbedding($0) && !OllamaModels.isVision($0) }
    }

    /// Downloaded MLX models as (display, repo id).
    var mlxModels: [(label: String, id: String)] {
        MLXCache.installed().map { entry in
            (entry.repoID.split(separator: "/").last.map(String.init) ?? entry.repoID, entry.repoID)
        }
    }

    /// Configured OpenAI-compatible services (Groq / OpenRouter / Custom / OpenAI) for the header's
    /// quick switcher — one tap each switches to that service and its saved model. Hidden in
    /// local-only mode.
    var openAIServices: [(service: String, name: String, model: String)] {
        PrivacyMode.localOnly ? [] : intelligence.configuredOpenAIServices()
    }
    /// Cloud engines are only offered when configured (key + model) and not in local-only mode.
    var anthropicReady: Bool {
        !PrivacyMode.localOnly && !intelligence.anthropicModel.isEmpty
            && !(Keychain.getMigrating("anthropic.apiKey", legacyDefaultsKey: "anthropic.apiKey") ?? "").isEmpty
    }

    /// Switch the active text engine/model globally — persists exactly like Settings would, so it
    /// affects capture actions too. Cloud switches keep whatever model is configured in Settings.
    func selectTextModel(_ provider: ProviderKind, model: String = "") {
        intelligence.preferred = provider
        switch provider {
        case .ollama: if !model.isEmpty { intelligence.ollamaModel = model }
        case .mlx:    if !model.isEmpty { intelligence.mlxModel = model }
        case .onDevice, .openAICompatible, .anthropic: break
        }
        Task { await refreshCapabilities() }
    }

    /// Whether `provider` (+`model`) is the active text engine — drives the menu checkmarks.
    func isCurrentTextModel(_ provider: ProviderKind, model: String = "") -> Bool {
        guard intelligence.effectivePreferred == provider else { return false }
        switch provider {
        case .ollama: return model.isEmpty || intelligence.ollamaModel == model
        case .mlx: return model.isEmpty
            || MLXProvider.normalizedID(intelligence.mlxModel) == MLXProvider.normalizedID(model)
        default: return true
        }
    }

    /// Switch to a specific OpenAI-compatible service (Groq / OpenRouter / Custom / OpenAI) and its
    /// saved model — global, persists, matches Settings.
    func selectOpenAIService(_ service: String) {
        intelligence.switchOpenAIService(service)
        Task { await refreshCapabilities() }
    }
    func isCurrentOpenAIService(_ service: String) -> Bool {
        intelligence.effectivePreferred == .openAICompatible && intelligence.activeOpenAIService == service
    }

    /// OCR the attached image locally; nil if there's no readable text.
    private func recognizeText(_ image: CGImage) async -> String? {
        guard let result = try? await ocr.recognize(image), !result.isEmpty else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Any web or reverse-image connector active (respecting local-only mode).
    static func computeWebAvailable() -> Bool {
        Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive() || Connectors.googleVision.isActive()
    }

    // MARK: - Slash commands

    /// `/clear` (or `/reset`) — clears the conversation and starts fresh. Case-insensitive, tolerant
    /// of a trailing slash so it fires the moment the whole command is typed.
    static func isClearCommand(_ typed: String) -> Bool {
        let t = typed.lowercased()
        return t == "/clear" || t == "/reset"
    }

    // MARK: - Web grounding intent

    /// Whether a turn plausibly benefits from web/connector grounding. The globe toggle means "ground
    /// *when it helps*", not "search every message" — so even with it on we skip turns that gain
    /// nothing from a lookup: greetings and small talk, and self-contained creative/transform asks
    /// (write / rewrite / translate / summarize / fix-this-code). Image turns always benefit
    /// (reverse-image identification), so they're never gated. Errs toward searching when unsure, so
    /// real questions still get grounded.
    static func turnBenefitsFromWeb(typed: String, hasImage: Bool) -> Bool {
        if hasImage { return true }
        let t = normalizeForIntent(typed)
        guard !t.isEmpty else { return false }
        if isSmallTalk(t) || isSelfContainedTask(t) { return false }
        return true
    }

    /// Lowercased, trimmed, with surrounding whitespace/punctuation stripped — for whole-message matching.
    private static func normalizeForIntent(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?,…"))
    }

    /// Whole-message greetings, acknowledgements, and meta questions about the assistant. Token-based:
    /// a short message made up *entirely* of pleasantry words is small talk — so "hello", "hello how
    /// are you", and "thanks so much" all count, while "hello what is the capital of France" does not
    /// (the moment a non-pleasantry word like "capital" appears, it's a real question). The exact set
    /// covers a few multi-word meta phrases the token check would otherwise miss.
    private static func isSmallTalk(_ t: String) -> Bool {
        let exact: Set<String> = [
            "who are you", "what are you", "what is your name", "what's your name", "whats your name",
            "introduce yourself", "how does this work", "what can you do",
        ]
        if exact.contains(t) { return true }

        let words = t.split(whereSeparator: { $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?'\"")) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 6 else { return false }
        let pleasantries: Set<String> = [
            "hello", "helo", "hi", "hii", "hey", "heya", "hiya", "yo", "sup", "wassup", "greetings",
            "good", "morning", "afternoon", "evening", "night", "how", "are", "you", "u", "r", "ya",
            "is", "it", "going", "hows", "whats", "doing", "today", "there", "friend", "mate", "well",
            "thanks", "thank", "thx", "ty", "cheers", "a", "lot", "so", "much", "appreciate", "please",
            "ok", "okay", "k", "kk", "got", "cool", "nice", "great", "awesome", "perfect", "lovely",
            "lol", "haha", "hmm", "yeah", "yep", "yes", "no", "nope", "bye", "goodbye", "see", "later",
            "and", "to", "meet", "nice", "im", "i'm", "me", "my", "name",
        ]
        return words.allSatisfy { pleasantries.contains($0) }
    }

    /// Imperative creative / transform / coding asks — the material is supplied or generated, not
    /// looked up — so web evidence is just latency and noise.
    private static func isSelfContainedTask(_ t: String) -> Bool {
        let prefixes = [
            "write ", "write me ", "help me write", "draft ", "help me draft", "compose ",
            "rewrite ", "reword ", "rephrase ", "paraphrase ", "summarize ", "summarise ",
            "translate ", "fix ", "debug ", "refactor ", "proofread ", "polish ", "shorten ",
            "expand ", "brainstorm ", "make me ", "give me ideas", "list some ideas",
        ]
        if prefixes.contains(where: { t.hasPrefix($0) }) { return true }
        let phrases = ["tl;dr", "this code", "the following code", "fix this", "explain this code"]
        return phrases.contains(where: { t.contains($0) })
    }

    // MARK: - Sending

    /// Send a message. `text` overrides the composer (used by the suggestion chips); `extraContext`
    /// is a one-shot context folded into *only this* turn (e.g. Lasso's feature list for the
    /// "What can you do?" chip) — it never becomes a standing system prompt, so normal chats stay clean.
    func send(text: String? = nil, extraContext: String? = nil, webSearch: Bool? = nil) {
        if let text { input = text }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Slash commands typed in the composer act on the session, not the model. `/clear` resets to
        // a fresh chat (history, attachment, seeded context) — intercepted before any turn is built.
        if Self.isClearCommand(typed) {
            Log.chat.notice("send: /clear — resetting session")
            newChat()
            return
        }

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

        // Whether grounding is *allowed* this turn: the user's globe toggle (a chip can force it off,
        // e.g. "What can you do?") and at least one active connector. Whether to *actually* search is
        // decided downstream — by the model via a tool when the provider supports it, otherwise by the
        // local heuristic — so simple chat (greetings, write/translate) stays fast and quiet.
        let allowGround = (webSearch ?? webSearchOn) && webConnectorsAvailable

        Log.chat.notice("send: typedChars=\(typed.count, privacy: .public) hasImage=\(image != nil, privacy: .public) allowGround=\(allowGround, privacy: .public) history=\(self.messages.count, privacy: .public)")
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runTurn(typed: typed, image: image, context: context, appContext: extraContext,
                                allowGround: allowGround, userID: userID, assistantID: assistantID)
        }
    }

    private func runTurn(typed: String, image: CGImage?, context: String?, appContext: String?,
                         allowGround: Bool, userID: UUID, assistantID: UUID) async {
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

        // OCR any text in the attached image (fast, local) — sharpens both the answer and the web
        // query (brand/model/signage). Skip when we already have seeded capture text.
        var ocrText: String?
        if let image, (context?.isEmpty ?? true) {
            ocrText = await recognizeText(image)
            if let ocrText { Log.chat.notice("runTurn · OCR \(ocrText.count, privacy: .public) chars (+\(ms(), privacy: .public)ms)") }
        }

        // Grounding routing. A cheap heuristic pre-filter runs on BOTH paths: obvious no-search turns
        // (greetings/small talk, write/translate/summarize) never ground — so the model can't
        // over-search a "hello how are you". For turns that pass, a tool-capable provider gets a
        // `web_search` tool and the *model* makes the final call (industry standard); otherwise we
        // fall back to the local heuristic and pre-gather evidence.
        let benefits = Self.turnBenefitsFromWeb(typed: typed, hasImage: image != nil)
        let providerTools = allowGround ? await intelligence.activeTextProviderSupportsTools() : false
        let toolPath = allowGround && providerTools && benefits
        let heuristicGround = allowGround && !providerTools && benefits
        if allowGround && !benefits {
            Log.chat.notice("runTurn · grounding skipped — turn doesn't benefit from web (pre-filter)")
        }
        Log.chat.notice("runTurn · grounding route: toolPath=\(toolPath, privacy: .public) heuristic=\(heuristicGround, privacy: .public) benefits=\(benefits, privacy: .public)")

        async let evidenceResult = gatherEvidence(typed: typed, boxed: boxed,
                                                  ocrText: ocrText, enabled: heuristicGround)

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
                        "No image model is set. Choose one under Settings ▸ Intelligence ▸ Image model "
                        + "(a local Ollama vision model, or a multimodal cloud model) to chat about images.")
                    return
                } else if let describeError {
                    // The image model exists but the request failed (timeout / rate-limit / offline).
                    finishError(assistantID,
                        "The image model (\(label)) couldn't read this image: "
                        + "\(describeError.localizedDescription) It may be slow, rate-limited, or "
                        + "offline — try again, or switch image models in Settings ▸ Intelligence ▸ Image model.")
                    return
                } else {
                    finishError(assistantID,
                        "The image model (\(label)) returned no description. Try again, or switch "
                        + "models in Settings ▸ Intelligence ▸ Image model.")
                    return
                }
            }
        }

        // Fold any OCR'd text into the turn so the model can use it directly.
        if let ocrText, !ocrText.isEmpty {
            userText += "\n\nText visible in the image:\n\(ocrText)"
        }

        // Fold in the connector evidence started above (waits only if it's still running). Tool-path
        // turns gather via the model's tool call instead, so this whole block is heuristic-only.
        let searchStepID: UUID? = heuristicGround
            ? addStep(assistantID, icon: "globe", text: "Searching the web…") : nil
        if heuristicGround {
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
        let turns = buildTurns(newUserText: userText, imageBase64: imageBase64)
        let totalChars = turns.reduce(0) { $0 + $1.text.count }
        Log.chat.notice("runTurn · built \(turns.count, privacy: .public) turns, \(totalChars, privacy: .public) chars, toolPath=\(toolPath, privacy: .public) — stream START (+\(ms(), privacy: .public)ms)")
        if Task.isCancelled { Log.chat.notice("runTurn · cancelled before stream"); return }

        // On the tool path the model may search first, so the "Searching…" step is added by the
        // executor — defer the answer step until the first answer token, so the trace reads
        // Search → Answer. Otherwise add it up front (with the cold-load hint).
        var answerStepID: UUID? = toolPath ? nil : addStep(assistantID, icon: "sparkles", text: "Answering · \(textLabel)")

        // If no token arrives within a few seconds, say why: a local model is cold-loading into
        // memory ("first use can take a while"); a cloud model is just slow/busy on the network.
        let coldLoadHint = intelligence.effectivePreferred.isLocalKind
            ? "Loading \(textLabel)… (first use can take a while)"
            : "Waiting for \(textLabel)…"
        let loadingHint: Task<Void, Never>? = answerStepID.map { stepID in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                self?.setStepText(assistantID, stepID, coldLoadHint)
            }
        }

        // The web_search tool executor (used only on the tool path): runs the user's connectors for
        // the model's query, surfaces a "Searching…" step, and returns evidence text to ground on.
        let toolBoxed = boxed
        let toolOCR = ocrText
        let executor: ToolExecutor = { [weak self] call in
            guard let self else { return "Web search is unavailable." }
            let query = call.string("query") ?? typed
            return await self.runWebSearchTool(query: query, boxed: toolBoxed,
                                               ocrText: toolOCR, assistantID: assistantID)
        }

        var deltas = 0
        var chars = 0
        var firstTokenMs = -1
        var raw = ""              // full stream, so we can split <think> reasoning from the answer
        var thinkStart: Date?
        do {
            let stream = toolPath
                ? intelligence.respond(messages: turns, tools: [.webSearch], execute: executor)
                : intelligence.respond(messages: turns)
            for try await delta in stream {
                if Task.isCancelled { loadingHint?.cancel(); Log.chat.notice("runTurn · cancelled mid-stream after \(chars, privacy: .public) chars"); return }
                if firstTokenMs < 0 {
                    firstTokenMs = ms(); loadingHint?.cancel()
                    if let answerStepID { setStepText(assistantID, answerStepID, "Answering · \(textLabel)") }
                    else { answerStepID = addStep(assistantID, icon: "sparkles", text: "Answering · \(textLabel)") }
                    Log.chat.notice("runTurn · first token (+\(firstTokenMs, privacy: .public)ms)")
                }
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
            loadingHint?.cancel()
            if let answerStepID { completeStep(assistantID, answerStepID, text: "Answered · \(textLabel)") }
        } catch {
            loadingHint?.cancel()
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
    private func gatherEvidence(typed: String, boxed: UncheckedImage?, ocrText: String?,
                                enabled: Bool) async -> Evidence? {
        guard enabled, !PrivacyMode.localOnly else { return nil }
        let image = boxed?.cg
        let webActive = Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive()
        let reverseActive = image != nil && Connectors.googleVision.isActive()
        guard webActive || reverseActive else { return nil }

        var evidence = Evidence()
        if reverseActive, let image {
            evidence.merge(await GoogleVisionSource().gather(image: image, query: typed, ocrText: ocrText))
        }
        if webActive {
            let query = Self.searchQuery(bestGuess: evidence.bestGuess, entity: evidence.entities.first,
                                         typed: typed, ocrText: ocrText)
            if !query.isEmpty {
                let result = await WebSourcesProvider().lookup(query)
                evidence.merge(Evidence(abstract: result.abstract, hits: result.hits))
            }
        }
        return evidence.isEmpty ? nil : evidence
    }

    /// Build the strongest web query by fusing signals: reverse-image identity, any text seen in the
    /// image (brand/model/signage), and the user's question — far more specific than a single label.
    private static func searchQuery(bestGuess: String?, entity: String?,
                                    typed: String, ocrText: String?) -> String {
        var parts: [String] = []
        if let g = bestGuess, !g.isEmpty { parts.append(g) }
        if let o = ocrText, !o.isEmpty { parts.append(keyTerms(o)) }
        if !typed.isEmpty, !isGenericQuestion(typed) { parts.append(typed) }
        if parts.isEmpty, let e = entity, !e.isEmpty { parts.append(e) }
        if parts.isEmpty, !typed.isEmpty { parts.append(typed) }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First ~10 words of OCR text — enough for a brand/model without dumping a whole sign.
    private static func keyTerms(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(10).joined(separator: " ")
    }

    /// Generic "what is this"-style questions add no search signal, so they're dropped from the query.
    private static func isGenericQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let generics = ["what is this", "what's this", "whats this", "what is it", "identify this",
                        "what am i looking at", "describe this", "what do you see"]
        return generics.contains { t == $0 || t == $0 + "?" }
    }

    /// Tool executor body (industry-standard path): run the user's connectors for the model's `query`
    /// — plus reverse-image when an image is attached — surface the activity in the trace, and return
    /// a text block for the model to ground its answer on. Mirrors the heuristic path's evidence, just
    /// driven by the model's own decision to search.
    private func runWebSearchTool(query: String, boxed: UncheckedImage?, ocrText: String?,
                                  assistantID: UUID) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.chat.notice("web_search executor: query=\(q, privacy: .public)")
        let stepID = addStep(assistantID, icon: "globe",
                             text: q.isEmpty ? "Searching the web…" : "Searching: \(q)")
        guard let evidence = await gatherEvidence(typed: q, boxed: boxed, ocrText: ocrText, enabled: true) else {
            completeStep(assistantID, stepID, text: "No web results")
            return "No results found for \"\(q)\"."
        }
        let hits = Array(evidence.hits.prefix(6))
        update(assistantID) { $0.sources = hits }
        var summary = "Found \(hits.count) source\(hits.count == 1 ? "" : "s")"
        if let guess = evidence.bestGuess, !guess.isEmpty { summary = "Identified “\(guess)” · " + summary }
        completeStep(assistantID, stepID, text: summary, links: hits)
        let body = Self.formatEvidence(evidence)
        return body.isEmpty ? "No useful results found." : body
    }

    /// Fold gathered evidence into the turn as grounding context for the model (heuristic path).
    private func appendEvidence(_ text: String, _ evidence: Evidence) -> String {
        let body = Self.formatEvidence(evidence)
        guard !body.isEmpty else { return text }
        return """
        \(text)

        [Web evidence gathered for this question — ground your answer in it; do not invent facts it \
        doesn't support. Do NOT paste these URLs or add a Sources list — the app shows them separately:]
        \(body)
        """
    }

    /// Render gathered evidence as plain text — shared by the heuristic fold-in and the tool result.
    private static func formatEvidence(_ evidence: Evidence) -> String {
        var lines: [String] = []
        if let g = evidence.bestGuess, !g.isEmpty {
            lines.append("Likely identification (reverse-image search): \(g)")
        }
        if !evidence.entities.isEmpty {
            lines.append("Related entities: \(evidence.entities.prefix(6).joined(separator: ", "))")
        }
        if let a = evidence.abstract, !a.isEmpty { lines.append("Reference summary: \(a)") }
        if !evidence.hits.isEmpty {
            // Include short page extracts (snippets) where available, not just titles, so the model
            // grounds on facts.
            let src = evidence.hits.prefix(6).map { hit -> String in
                var line = "- \(hit.title)"
                if let url = hit.url { line += " (\(url.absoluteString))" }
                if let snippet = hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !snippet.isEmpty {
                    line += "\n  \(snippet.prefix(280))"
                }
                return line
            }.joined(separator: "\n")
            lines.append("Sources:\n\(src)")
        }
        return lines.joined(separator: "\n")
    }

    /// Build the budgeted `[ChatTurn]` to send: system + rolling summary + recent verbatim turns +
    /// the new (folded) user turn. Delegates layout/budget to `ChatContextBuilder`; older turns that
    /// fall outside the recent window are represented by `rollingSummary` (kept fresh in the
    /// background) instead of being dropped.
    private func buildTurns(newUserText: String, imageBase64: String?) -> [ChatTurn] {
        // Map the prior history (excluding the just-appended user-display + assistant-placeholder)
        // to the builder's history turns, using each message's persisted `promptText` so folded
        // image/evidence context carries. Assistant thoughts are stripped — they're UI affordances.
        let history = Self.historyTurns(from: messages.dropLast(2))

        let out = contextBuilder.build(systemPrompt: Self.systemPrompt,
                                       summary: rollingSummary,
                                       history: history,
                                       currentUserText: newUserText,
                                       currentImageBase64: imageBase64)
        trimmedNotice = out.didCompress

        // Fold the now-out-of-window turns into the rolling summary off the send path. No-op when
        // everything's already represented, so steady-state turns cost nothing extra.
        scheduleSummaryUpdate(overflow: out.overflow)

        return out.turns
    }

    /// Map visible `ChatMessage`s to the context builder's `HistoryTurn`s — the exact text the model
    /// saw (`promptText`), `<think>` stripped on assistant turns. Shared by `buildTurns` and the
    /// background summarizer so both work off identical content.
    private static func historyTurns(from messages: ArraySlice<ChatMessage>) -> [ChatContextBuilder.HistoryTurn] {
        messages.map { m in
            let role: ChatTurn.Role = m.role == .user ? .user : .assistant
            let text = role == .assistant
                ? Self.stripThoughtBlocks(from: m.promptText ?? m.text)
                : (m.promptText ?? m.text)
            return .init(role: role, text: text, imageBase64: m.imageBase64)
        }
    }

    // MARK: - Background summarization

    /// Fold the turns that scrolled out of the recent window into `rollingSummary`, using the active
    /// provider. Runs in a cancellable background `Task` — never on `send` — so it can't block a
    /// reply. Incremental: only the overflow turns not yet covered by the summary are summarized, so
    /// steady-state sends do no extra work.
    private func scheduleSummaryUpdate(overflow: [ChatContextBuilder.HistoryTurn]) {
        // Only the overflow turns we haven't already summarized.
        guard overflow.count > summarizedTurnCount else { return }
        let newTurns = Array(overflow.suffix(from: summarizedTurnCount))
        let priorSummary = rollingSummary
        let coveredCount = overflow.count

        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            guard let self else { return }
            let transcript = Self.transcript(of: newTurns)
            guard !transcript.isEmpty else { return }
            let prompt = Self.summarizationPrompt(prior: priorSummary, newTranscript: transcript)
            // A plain single-turn request through the active provider — provider-agnostic, no tools,
            // no grounding. Keep it tight; strip any <think> the model emits.
            var raw = ""
            do {
                for try await delta in self.intelligence.respond(prompt: prompt, context: nil) {
                    if Task.isCancelled { return }
                    raw += delta
                }
            } catch {
                Log.chat.error("summary update FAILED: \(error.localizedDescription, privacy: .public)")
                return   // keep the prior summary; we'll retry on the next overflow.
            }
            if Task.isCancelled { return }
            let summary = Self.stripThoughtBlocks(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }
            // Commit on the main actor; guard against a `newChat()` having raced in (count reset to 0
            // with a shorter overflow than we computed against).
            guard coveredCount >= self.summarizedTurnCount else { return }
            self.rollingSummary = summary
            self.summarizedTurnCount = coveredCount
            Log.chat.notice("summary updated: covers \(coveredCount, privacy: .public) turns, \(summary.count, privacy: .public) chars")
        }
    }

    /// Render history turns as a compact transcript for the summarizer.
    private static func transcript(of turns: [ChatContextBuilder.HistoryTurn]) -> String {
        turns.map { turn -> String in
            let speaker = turn.role == .user ? "User" : "Assistant"
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "" : "\(speaker): \(body)"
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Tight summarization instruction: evolve the prior summary with the new exchanges into one
    /// compact recap. Model-agnostic and deliberately small so even a 0.6B model can follow it.
    private static func summarizationPrompt(prior: String, newTranscript: String) -> String {
        let priorBlock = prior.isEmpty
            ? "There is no earlier summary yet."
            : "Current running summary so far:\n\(prior)"
        return """
        You are maintaining a running summary of an ongoing chat so a later assistant can stay \
        coherent without the full history. Update the summary to incorporate the new exchanges below.

        Keep it compact (a few short sentences or terse bullet points, well under 200 words). Preserve \
        durable facts the user shared, their goal/task, decisions made, named entities, and any open \
        questions or constraints. Drop greetings, filler, and anything superseded. Write it as plain \
        notes — no preamble, no "here is the summary", no markdown headings. Output only the updated \
        summary.

        \(priorBlock)

        New exchanges to fold in:
        \(newTranscript)
        """
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

    /// Update an in-progress step's text (without marking it done).
    private func setStepText(_ id: UUID, _ stepID: UUID, _ text: String) {
        update(id) { msg in
            if let i = msg.steps.firstIndex(where: { $0.id == stepID }) { msg.steps[i].text = text }
        }
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
