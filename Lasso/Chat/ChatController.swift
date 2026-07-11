import AppKit
import CoreGraphics
import KeyboardShortcuts
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

    // MARK: - Sessions (the panel holds several conversations; one is `active`)

    /// All open conversations, oldest-first. Bounded by `maxSessions`.
    private(set) var sessions: [Conversation]
    /// The conversation currently shown in the panel — all the send/memory logic drives this one.
    private(set) var active: Conversation
    /// Cap on retained in-session conversations (bounds memory: each holds messages + a semantic index).
    static let maxSessions = 12
    /// Max images per turn — keeps context/token cost bounded.
    static let maxAttachments = 5

    // Per-conversation state forwards to the active session, so the existing send/runTurn/memory logic
    // works unchanged while the panel can hold several conversations. Background tasks capture their
    // own session (see `scheduleIndex` / `scheduleSummaryUpdate`), so switching never crosses streams.
    var messages: [ChatMessage] { get { active.messages } set { active.messages = newValue } }
    var input: String { get { active.input } set { active.input = newValue } }
    var pendingAttachments: [Attachment] { get { active.pendingAttachments } set { active.pendingAttachments = newValue } }
    var seededContext: String? { get { active.seededContext } set { active.seededContext = newValue } }
    var isStreaming: Bool { get { active.isStreaming } set { active.isStreaming = newValue } }
    private var streamTask: Task<Void, Never>? { get { active.streamTask } set { active.streamTask = newValue } }
    private var memory: ConversationMemory { get { active.memory } set { active.memory = newValue } }
    private var summarizedTurnCount: Int { get { active.summarizedTurnCount } set { active.summarizedTurnCount = newValue } }
    private var summaryTask: Task<Void, Never>? { get { active.summaryTask } set { active.summaryTask = newValue } }
    private var memoryIndex: ChatMemoryIndex { active.memoryIndex }
    private var indexTask: Task<Void, Never>? { get { active.indexTask } set { active.indexTask = newValue } }

    // MARK: - Global capabilities / preferences (shared across all sessions)

    /// Whether attaching an image can do anything useful right now (native vision or a vision provider).
    private(set) var imageInputAvailable = false
    /// Whether any web-search connector is configured (drives the globe toggle's visibility).
    private(set) var webConnectorsAvailable = false
    /// User-facing toggle: ground answers with web/connector evidence. Persisted, defaults off.
    var webSearchOn: Bool {
        didSet { UserDefaults.standard.set(webSearchOn, forKey: Self.webSearchKey) }
    }
    private static let webSearchKey = "chat.webSearchOn"

    /// The budgeted assembler — char-based, provider-agnostic. Shared (stateless) across sessions.
    private let contextBuilder = ChatContextBuilder()

    private init() {
        // Restore persisted conversations (Application Support — survives app updates/reinstall). The
        // semantic index isn't stored; it rebuilds lazily (see `reindexActive`).
        let restored = ConversationStore.loadAll().map(ConversationStore.rebuild)
        if let last = restored.last {
            sessions = restored
            active = last
        } else {
            let first = Conversation()
            sessions = [first]
            active = first
        }
        // Default off; restore the user's last choice if they ever set it.
        webSearchOn = UserDefaults.standard.object(forKey: Self.webSearchKey) as? Bool ?? false
        // Lazily rebuild the active conversation's semantic index from its restored messages.
        reindexActive()
    }

    // MARK: - Persistence (Application Support; source-of-truth only, index is derived)

    /// Persist one conversation (its own file) and refresh the shared index. Skips empty conversations
    /// (nothing to save until they have content). Disk I/O runs off the main actor.
    private func persist(_ c: Conversation) {
        let entries = sessions.filter(\.hasMessages).map(ConversationStore.indexEntry)
        guard c.hasMessages else {
            Task.detached(priority: .utility) { ConversationStore.writeIndex(entries) }
            return
        }
        let dto = ConversationStore.snapshot(c)
        let thumbs = ConversationStore.thumbnailJobs(c)
        Task.detached(priority: .utility) {
            ConversationStore.writeConversation(dto, thumbnails: thumbs)
            ConversationStore.writeIndex(entries)
        }
    }

    /// Rebuild the active conversation's semantic index from its (possibly restored) messages. The
    /// index cursor makes this a no-op once caught up, so it's cheap to call on load and on switch.
    private func reindexActive() {
        guard active.hasMessages else { return }
        scheduleIndex()
    }

    /// The user changed the embedding backend (Settings ▸ Intelligence ▸ Embedding model). Vectors from
    /// a different embedder aren't comparable, so every session's index is fully reset + its cached
    /// embedder cleared; the active one re-embeds now, the rest lazily when next viewed.
    func embeddingConfigChanged() {
        for s in sessions {
            s.indexTask?.cancel(); s.indexTask = nil
            s.memoryIndex.reset()
            s.memoryIndex.clearEmbedderCache()
        }
        reindexActive()
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
    /// Shortcuts are read live so the model never states a stale key combo after the user rebinds.
    static var lassoCapabilities: String {
        let capture = KeyboardShortcuts.Name.capture.displayString ?? "its Capture shortcut"
        let chat = KeyboardShortcuts.Name.chat.displayString ?? "its Chat shortcut"
        return """
    Context about Lasso — the macOS menu-bar app you are the assistant inside (answer questions about \
    what Lasso can do using only this):
    • Capture: press \(capture) to select any region of the screen. On a selection you can Copy text \
    (OCR), Translate it (including in-place overlay), Summarize, Ask AI about it, Identify what it is, \
    open detected QR/barcodes, pick a color, copy or save the image, or “Continue in chat”. Detected \
    links, phone numbers, emails and dates appear as quick action chips.
    • Chat (this panel): press \(chat). Multi-turn conversation, attach images (button, ⌘V paste, or \
    drag-and-drop), and optional web grounding.
    • Models: choose a Language model and a separate Image (vision) model independently — Apple \
    Intelligence, local Ollama, local MLX, or a cloud model (OpenAI-compatible / Anthropic). \
    On-device and private by default; cloud is opt-in; a Local-only mode blocks all non-local calls.
    • Connectors (optional): Web search (Wikipedia / DuckDuckGo / Reddit), plus Tavily or SerpApi for \
    stronger ranked results — these ground answers with real sources. (Reverse-image search lives in \
    Identify, via Google Lens.)
    Be concise and accurate; don’t invent features not listed here.
    """
    }

    // MARK: - Composer state

    /// Append an image to the composer (up to `maxAttachments`).
    func attach(_ image: CGImage) {
        guard pendingAttachments.count < Self.maxAttachments else { return }
        pendingAttachments.append(Attachment(image: image))
    }
    func removeAttachment(_ id: UUID) { pendingAttachments.removeAll { $0.id == id } }
    func clearAttachments() { pendingAttachments.removeAll() }
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

    var hasMessages: Bool { active.hasMessages }
    /// Whether the active conversation has anything to clear (drives the New chat affordance).
    var canClear: Bool { active.canClear }

    // MARK: - Session management

    /// Recents-menu rows (id, title, icon, active flag), most-recent first. Only conversations with
    /// content are listed — a pristine "New conversation" has no title of its own and would just collide
    /// with the "New conversation" action (and the header already shows the active one).
    var sessionSummaries: [(id: UUID, title: String, systemImage: String, isActive: Bool)] {
        sessions.reversed().filter(\.hasMessages).map { ($0.id, $0.title, $0.systemImage, $0.id == active.id) }
    }

    /// The active conversation as a clean, role-labeled Markdown transcript — for one-click "Copy
    /// conversation" (e.g. to paste into another AI). Skips streaming/errored/empty turns; notes images.
    var transcriptText: String {
        active.messages.compactMap { m -> String? in
            guard !m.isStreaming, !m.isError else { return nil }
            let role = m.role == .user ? "You" : "Assistant"
            var body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.attachments.isEmpty {
                let note = "[\(m.attachments.count) image\(m.attachments.count == 1 ? "" : "s")]"
                body = body.isEmpty ? note : "\(note)\n\(body)"
            }
            guard !body.isEmpty else { return nil }
            return "\(role): \(body)"
        }.joined(separator: "\n\n")
    }

    /// Append a local, non-model message (e.g. `/help` output). Never sent to a provider; persisted so it
    /// scrolls with the thread, but it isn't indexed (no turn runs) so it won't pollute retrieval.
    func postLocalMessage(_ text: String) {
        active.messages.append(ChatMessage(role: .assistant, text: text))
        persist(active)
    }

    /// Start a brand-new empty conversation — keeps the current ones (no longer wipes). No-op when we're
    /// already in a pristine empty conversation, so clicking "New conversation" repeatedly can't pile up
    /// duplicate empties.
    func newChat() {
        guard active.canClear else { return }
        startSession(Conversation())
    }

    /// Switch the panel to another open conversation. Blocked mid-stream so a running turn keeps
    /// updating the session that started it.
    func switchTo(_ id: UUID) {
        guard !active.isStreaming, id != active.id,
              let target = sessions.first(where: { $0.id == id }) else { return }
        active = target
        reindexActive()   // rebuild its semantic index if it was restored from disk (no-op once caught up)
    }

    /// Remove a conversation (cancelling its work). If it was the active one, fall back to the most
    /// recent remaining; closing the last conversation leaves a fresh empty one.
    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].cancelWork()
        let wasActive = sessions[idx].id == active.id
        sessions.remove(at: idx)
        ConversationStore.delete(id: id)   // drop its file; index is rewritten below
        if sessions.isEmpty {
            let fresh = Conversation()
            sessions = [fresh]
            active = fresh
        } else if wasActive {
            active = sessions.last!
            reindexActive()
        }
        persist(active)   // rewrite the shared index to reflect the removal
    }

    /// Close the conversation currently shown (the recents menu's "Close" action).
    func closeActive() { close(active.id) }

    /// Open a *new* conversation seeded with a prior one-shot exchange (Ask AI's "Continue in chat") —
    /// the conversation you were in is preserved and reachable from the recents menu.
    func continueWith(question: String, answer: String, context: String?, image: CGImage?) {
        let s = Conversation()
        s.kind = .askAI
        if let image { s.anchor = .image(image) }
        else if let context, !context.isEmpty { s.anchor = .selection(context) }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = ChatMessage(role: .user, text: q.isEmpty ? "About this" : q,
                               attachments: image.map { [Attachment(image: $0)] } ?? [])
        if let context, !context.isEmpty {
            user.promptText = "Context — from my screen:\n\(context)\n\n\(q.isEmpty ? "About this" : q)"
        }
        s.messages.append(user)
        s.messages.append(ChatMessage(role: .assistant, text: answer))
        startSession(s)
    }

    /// Open a *new* conversation seeded from a capture (selection text and/or image) — preserves the
    /// current conversation.
    func seed(text: String?, image: CGImage?) {
        let s = Conversation()
        s.kind = image != nil ? .image : .selection
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        s.seededContext = (trimmed?.isEmpty == false) ? trimmed : nil
        if let image {
            s.pendingAttachments = [Attachment(image: image)]
            s.anchor = .image(image)
        } else if let trimmed, !trimmed.isEmpty {
            s.anchor = .selection(trimmed)
        }
        startSession(s)
    }

    /// Reset the ACTIVE conversation in place (`/clear`) — scoped to the current chat, not the others.
    func clearActive() {
        active.cancelWork()
        active.memoryIndex.reset()
        active.memory = ConversationMemory()
        active.summarizedTurnCount = 0
        active.messages.removeAll()
        active.input = ""
        active.pendingAttachments = []
        active.seededContext = nil
        active.isStreaming = false
        // The conversation is now empty — drop its persisted file and refresh the index.
        ConversationStore.delete(id: active.id)
        persist(active)
    }

    /// Wipe ALL persisted chat history (Settings → privacy). Cancels every session, clears disk, and
    /// leaves one fresh empty conversation.
    func clearAllHistory() {
        for s in sessions { s.cancelWork() }
        let fresh = Conversation()
        sessions = [fresh]
        active = fresh
        Task.detached(priority: .utility) { ConversationStore.clearAll() }
    }

    /// Append a session, make it active, and enforce the cap (drop the oldest non-active sessions).
    private func startSession(_ s: Conversation) {
        // If the outgoing conversation is mid-stream, stop it cleanly first — its streaming task writes
        // via the active-forwarding path, so it must be finalized before `active` moves.
        if active.isStreaming { cancelStreaming() }
        sessions.append(s)
        active = s
        var overflow = sessions.count - Self.maxSessions
        guard overflow > 0 else { return }
        sessions.removeAll { session in
            guard overflow > 0, session.id != active.id else { return false }
            session.cancelWork(); overflow -= 1; return true
        }
        persist(active)   // a seeded conversation (Ask AI / capture) already has content worth saving
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

    /// Any web-search connector active (respecting local-only mode).
    static func computeWebAvailable() -> Bool {
        Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive()
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
    // MARK: - Per-message actions (hover ⋯ menu)

    /// Delete a message's whole exchange (question + its answer), whichever half was clicked — so you
    /// never leave an orphaned question or a reply with no question. Everything else stays.
    func deleteMessage(_ id: UUID) {
        guard !active.isStreaming, let idx = active.messages.firstIndex(where: { $0.id == id }) else { return }
        var lo = idx, hi = idx
        if active.messages[idx].role == .user {
            if idx + 1 < active.messages.count, active.messages[idx + 1].role == .assistant { hi = idx + 1 }
        } else if idx > 0, active.messages[idx - 1].role == .user {
            lo = idx - 1   // assistant reply → also drop the question it answered
        }
        active.messages.removeSubrange(lo...hi)
        historyDidChange()
    }

    /// Truncate the conversation from a message downward — remove it (from the start of its exchange)
    /// and everything after. Complements the surgical `deleteMessage`.
    func deleteFromHere(_ id: UUID) {
        guard !active.isStreaming, let idx = active.messages.firstIndex(where: { $0.id == id }) else { return }
        var start = idx
        if active.messages[idx].role == .assistant, idx > 0, active.messages[idx - 1].role == .user {
            start = idx - 1   // begin at the question this reply belongs to
        }
        active.messages.removeSubrange(start..<active.messages.count)
        historyDidChange()
    }

    /// Re-run a user message **in place**: drop its old answer + everything after, then re-send the same
    /// text/images so a fresh reply replaces the old one (no duplicate appended at the bottom). Same
    /// effect as Regenerate on the paired reply, just triggered from the question side.
    func resendMessage(_ id: UUID) {
        guard !active.isStreaming,
              let idx = active.messages.firstIndex(where: { $0.id == id }),
              active.messages[idx].role == .user else { return }
        let m = active.messages[idx]
        active.messages.removeSubrange(idx..<active.messages.count)
        resetDerivedMemory()
        active.input = m.text
        active.pendingAttachments = m.attachments
        send()
    }

    /// Commit an inline edit of a user message (called on **Send**, not when Edit is clicked — so Cancel
    /// leaves the thread untouched): replace it and drop everything after (editing rewrites the past),
    /// then re-send the new text with the original images.
    func submitEdit(_ id: UUID, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isStreaming, !text.isEmpty,
              let idx = active.messages.firstIndex(where: { $0.id == id }),
              active.messages[idx].role == .user else { return }
        let atts = active.messages[idx].attachments
        active.messages.removeSubrange(idx..<active.messages.count)
        resetDerivedMemory()
        active.input = text
        active.pendingAttachments = atts
        send()
    }

    /// Regenerate an assistant reply: drop this turn **and everything after** (they answered the old
    /// reply), then re-send its user turn for a new answer. On the last turn this is just "try again";
    /// on a middle turn it rewrites forward from that point (no reordering).
    func regenerate(_ id: UUID) {
        guard !active.isStreaming, let aIdx = active.messages.firstIndex(where: { $0.id == id }),
              active.messages[aIdx].role == .assistant,
              let uIdx = active.messages[..<aIdx].lastIndex(where: { $0.role == .user }) else { return }
        let userMsg = active.messages[uIdx]
        active.messages.removeSubrange(uIdx..<active.messages.count)
        resetDerivedMemory()
        active.input = userMsg.text
        active.pendingAttachments = userMsg.attachments
        send()
    }

    /// Drop **both** derived memories after a history edit — the semantic index *and* the running
    /// two-track summary. Resetting only the index left deleted facts alive in `durableFacts`/`topicTrace`
    /// (the model still "knew" a deleted fact). Both rebuild from the remaining messages: the index
    /// lazily via `reindexActive`, the summary on the next turn's overflow.
    private func resetDerivedMemory() {
        active.indexTask?.cancel()
        active.summaryTask?.cancel()
        active.memoryIndex.reset()
        active.memory = ConversationMemory()
        active.summarizedTurnCount = 0
    }

    /// After an in-place history edit (delete/truncate): reset derived memory, lazily rebuild the index,
    /// and persist the trimmed conversation.
    private func historyDidChange() {
        resetDerivedMemory()
        reindexActive()
        persist(active)
    }

    func send(text: String? = nil, extraContext: String? = nil, webSearch: Bool? = nil) {
        if let text { input = text }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Slash commands typed in the composer act on the session, not the model. `/clear` resets to
        // a fresh chat (history, attachment, seeded context) — intercepted before any turn is built.
        if Self.isClearCommand(typed) {
            Log.chat.notice("send: /clear — resetting active session")
            clearActive()
            return
        }

        guard !typed.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isStreaming else { return }

        let attachments = pendingAttachments
        let context = seededContext
        let placeholder = attachments.count > 1 ? "Look at these images" : "Look at this image"

        let userMessage = ChatMessage(role: .user, text: typed.isEmpty ? placeholder : typed,
                                      attachments: attachments)
        messages.append(userMessage)
        let userID = userMessage.id
        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id

        input = ""
        pendingAttachments = []
        seededContext = nil
        isStreaming = true

        // Whether grounding is *allowed* this turn: the user's globe toggle (a chip can force it off,
        // e.g. "What can you do?") and at least one active connector. Whether to *actually* search is
        // decided downstream — by the model via a tool when the provider supports it, otherwise by the
        // local heuristic — so simple chat (greetings, write/translate) stays fast and quiet.
        let allowGround = (webSearch ?? webSearchOn) && webConnectorsAvailable

        Log.chat.notice("send: typedChars=\(typed.count, privacy: .public) images=\(attachments.count, privacy: .public) allowGround=\(allowGround, privacy: .public) history=\(self.messages.count, privacy: .public)")
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runTurn(typed: typed, attachments: attachments, context: context, appContext: extraContext,
                                allowGround: allowGround, userID: userID, assistantID: assistantID)
        }
    }

    private func runTurn(typed: String, attachments: [Attachment], context: String?, appContext: String?,
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
        var imageBase64s: [String] = []
        let multi = attachments.count > 1

        // Grounding uses at most one image (reverse-image is out anyway) — box the first for the tool path.
        let boxed = attachments.first.map { UncheckedImage(cg: $0.image) }

        // OCR every attachment (fast, local), labeled when there are several. Skip when we already have
        // seeded capture text. Built into a `let` so it can be safely sent into the grounding task below.
        var ocrParts: [String] = []
        if !attachments.isEmpty, (context?.isEmpty ?? true) {
            for (i, att) in attachments.enumerated() {
                if let t = await recognizeText(att.image), !t.isEmpty {
                    ocrParts.append(multi ? "Image \(i + 1):\n\(t)" : t)
                }
            }
        }
        let ocrText: String? = ocrParts.isEmpty ? nil : ocrParts.joined(separator: "\n\n")
        if let ocrText {
            Log.chat.notice("runTurn · OCR \(ocrText.count, privacy: .public) chars across \(attachments.count, privacy: .public) image(s) (+\(ms(), privacy: .public)ms)")
        }

        // Grounding routing. A cheap heuristic pre-filter runs on BOTH paths: obvious no-search turns
        // (greetings/small talk, write/translate/summarize) never ground — so the model can't
        // over-search a "hello how are you". For turns that pass, a tool-capable provider gets a
        // `web_search` tool and the *model* makes the final call (industry standard); otherwise we
        // fall back to the local heuristic and pre-gather evidence.
        let benefits = Self.turnBenefitsFromWeb(typed: typed, hasImage: !attachments.isEmpty)
        let providerTools = allowGround ? await intelligence.activeTextProviderSupportsTools() : false
        let toolPath = allowGround && providerTools && benefits
        let heuristicGround = allowGround && !providerTools && benefits
        if allowGround && !benefits {
            Log.chat.notice("runTurn · grounding skipped — turn doesn't benefit from web (pre-filter)")
        }
        Log.chat.notice("runTurn · grounding route: toolPath=\(toolPath, privacy: .public) heuristic=\(heuristicGround, privacy: .public) benefits=\(benefits, privacy: .public)")

        async let evidenceResult = gatherEvidence(typed: typed, boxed: boxed,
                                                  ocrText: ocrText, enabled: heuristicGround)

        if !attachments.isEmpty {
            let native = await intelligence.textModelSupportsVision()
            Log.chat.notice("runTurn · \(attachments.count, privacy: .public) image(s), native=\(native, privacy: .public) (+\(ms(), privacy: .public)ms)")
            if native {
                imageBase64s = attachments.compactMap { ImageEncoder.jpegBase64($0.image) }
                Log.chat.notice("runTurn · native encode \(imageBase64s.count, privacy: .public) image(s) (+\(ms(), privacy: .public)ms)")
            }
            if imageBase64s.isEmpty {
                // Text-only model: describe each image via the vision provider and fold them in (labeled).
                let vision = await intelligence.activeVisionProvider()
                let label = intelligence.imageEngineLabel
                guard let vision else {
                    finishError(assistantID,
                        "No image model is set. Choose one under Settings ▸ Intelligence ▸ Image model "
                        + "(a local Ollama vision model, or a multimodal cloud model) to chat about images.")
                    return
                }
                let stepID = addStep(assistantID, icon: "eye",
                                     text: "Looking at \(attachments.count) image\(multi ? "s" : "") · \(label)")
                // Describe images concurrently: a real speedup for HTTP vision (Ollama / cloud —
                // parallel requests); local MLX serializes safely on its `ModelContainer` actor (queued,
                // never concurrent-generate). `VisionProvider` is Sendable so it's safe to capture.
                let describeQuery = typed
                struct Described: Sendable { let index: Int; let text: String?; let error: String? }
                let results = await withTaskGroup(of: Described.self) { group in
                    for (i, att) in attachments.enumerated() {
                        group.addTask {
                            let prompt = describeQuery.isEmpty
                                ? "Describe this image in detail."
                                : "Describe this image in detail to help answer: \(describeQuery)"
                            do {
                                let d = try await vision.describe(att.image, prompt: prompt)
                                return Described(index: i, text: d.isEmpty ? nil : d, error: nil)
                            } catch {
                                Log.chat.error("runTurn · describe FAILED (image \(i + 1, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                                return Described(index: i, text: nil, error: error.localizedDescription)
                            }
                        }
                    }
                    var out: [Described] = []
                    for await r in group { out.append(r) }
                    return out
                }
                let ordered = results.sorted { $0.index < $1.index }
                var descriptions: [String] = []
                for r in ordered {
                    if let t = r.text { descriptions.append(multi ? "Image \(r.index + 1): \(t)" : t) }
                }
                if descriptions.isEmpty {
                    completeStep(assistantID, stepID, text: "Couldn't read the image\(multi ? "s" : "") · \(label)")
                    finishError(assistantID, ordered.compactMap(\.error).first.map {
                        "The image model (\(label)) couldn't read \(multi ? "these images" : "this image"): "
                        + "\($0) It may be slow, rate-limited, or offline — try again, "
                        + "or switch image models in Settings ▸ Intelligence ▸ Image model."
                    } ?? "The image model (\(label)) returned no description. Try again, or switch models in "
                        + "Settings ▸ Intelligence ▸ Image model.")
                    return
                }
                completeStep(assistantID, stepID,
                             text: "Looked at \(descriptions.count) image\(descriptions.count == 1 ? "" : "s") · \(label)")
                let joined = descriptions.joined(separator: "\n\n")
                userText = """
                [I attached \(attachments.count) image\(multi ? "s" : ""). A separate vision model produced \
                \(multi ? "these descriptions" : "this description") — treat \(multi ? "them" : "it") cautiously \
                and don't attribute \(multi ? "them" : "it") to me:]
                \(joined)

                \(typed.isEmpty ? (multi ? "What are these?" : "What is this?") : typed)
                """
            }
        }

        // Fold any OCR'd text into the turn so the model can use it directly.
        if let ocrText, !ocrText.isEmpty {
            userText += "\n\nText visible in the image\(multi ? "s" : ""):\n\(ocrText)"
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
        update(userID) { $0.promptText = userText; $0.imageBase64s = imageBase64s }

        // Pull relevant older exchanges back in verbatim (semantic recall; empty when nothing indexed
        // or no embedder). Runs before assembly so the builder can place them in their reserve.
        let retrieved = await retrieveMemory(currentUserText: userText)
        if !retrieved.isEmpty {
            Log.chat.notice("runTurn · retrieved \(retrieved.count, privacy: .public) memory chunk(s) (+\(ms(), privacy: .public)ms)")
            // Debug-level so it's visible in Xcode while testing but not persisted for regular users.
            for (i, chunk) in retrieved.enumerated() {
                let preview = String(chunk.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(140))
                Log.chat.debug("runTurn ·   retrieved[\(i, privacy: .public)]: \(preview, privacy: .public)")
            }
        }

        let textLabel = intelligence.textEngineLabel
        let turns = buildTurns(newUserText: userText, imageBase64s: imageBase64s, retrieved: retrieved)
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

    /// Gather evidence from the active connectors: a text web lookup (Wikipedia / DuckDuckGo / Reddit,
    /// plus optional Tavily / SerpApi) on the strongest query built from any typed question and
    /// on-screen text. Returns nil when nothing usable was found. (Reverse-image lives in the Lens
    /// panel now — it's a one-tap escalation, not a silent per-turn API call.)
    private func gatherEvidence(typed: String, boxed: UncheckedImage?, ocrText: String?,
                                enabled: Bool) async -> Evidence? {
        guard enabled, !PrivacyMode.localOnly else { return nil }
        let webActive = Connectors.webSearch.isActive() || Connectors.tavily.isActive()
            || Connectors.serpApi.isActive()
        guard webActive else { return nil }

        var evidence = Evidence()
        let query = Self.searchQuery(bestGuess: nil, entity: nil, typed: typed, ocrText: ocrText)
        if !query.isEmpty {
            let result = await WebSourcesProvider().lookup(query)
            evidence.merge(Evidence(abstract: result.abstract, hits: result.hits))
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
    private func buildTurns(newUserText: String, imageBase64s: [String], retrieved: [String] = []) -> [ChatTurn] {
        // Map the prior history (excluding the just-appended user-display + assistant-placeholder)
        // to the builder's history turns, using each message's persisted `promptText` so folded
        // image/evidence context carries. Assistant thoughts are stripped — they're UI affordances.
        let history = Self.historyTurns(from: messages.dropLast(2))

        let out = contextBuilder.build(systemPrompt: Self.systemPrompt,
                                       memory: memory,
                                       history: history,
                                       retrieved: retrieved,
                                       currentUserText: newUserText,
                                       currentImageBase64s: imageBase64s)
        // Not surfaced in the UI anymore (older turns aren't lost — they're summarized + retrievable);
        // kept as a dev-facing log signal.
        if out.didCompress { Log.chat.notice("context compressed — older turns folded into summary/retrieval") }

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
            return .init(role: role, text: text, imageBase64s: m.imageBase64s)
        }
    }

    // MARK: - Background summarization

    /// Fold the turns that scrolled out of the recent window into `memory`, using the active provider.
    /// Runs in a cancellable background `Task` — never on `send` — so it can't block a reply.
    /// Incremental: only the overflow turns not yet covered are summarized, so steady-state sends do
    /// no extra work.
    private func scheduleSummaryUpdate(overflow: [ChatContextBuilder.HistoryTurn]) {
        // Capture the session so this background work commits to the conversation it belongs to, even
        // if the user switches to another session before it finishes.
        let session = active
        // Only the overflow turns we haven't already summarized.
        guard overflow.count > session.summarizedTurnCount else { return }
        let newTurns = Array(overflow.suffix(from: session.summarizedTurnCount))
        let priorMemory = session.memory
        let coveredCount = overflow.count

        session.summaryTask?.cancel()
        session.summaryTask = Task { [weak self] in
            guard let self else { return }
            let transcript = Self.transcript(of: newTurns)
            guard !transcript.isEmpty else { return }
            let prompt = Self.summarizationPrompt(prior: priorMemory, newTranscript: transcript)
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
                return   // keep the prior memory; we'll retry on the next overflow.
            }
            if Task.isCancelled { return }
            let cleaned = Self.stripThoughtBlocks(from: raw)
            // Auto-name the conversation from the same pass (so long chats don't stay titled by their
            // first message). **Sticky:** set once — the first summary pass only fires after the chat
            // has overflowed the recent window (~8 messages), so there's enough substance to name it
            // well; regenerating every later pass just made the identity drift under the user. The
            // fallback title (first message / kind) still applies until this lands. Best-effort.
            if session.autoTitle?.isEmpty ?? true, let title = Self.parseTitle(from: cleaned) {
                session.autoTitle = title
                Log.chat.notice("conversation auto-titled: \(title, privacy: .public)")
            }
            // Parse the FACTS/TOPICS contract back into the struct; falls back gracefully on a sloppy
            // small-model response (never loses prior facts, never crashes).
            let updated = Self.parseMemory(from: cleaned, prior: priorMemory)
            guard !updated.isEmpty else { return }
            // Commit to the session; guard against a `/clear` having raced in (count reset shorter).
            guard coveredCount >= session.summarizedTurnCount else { return }
            session.memory = updated
            session.summarizedTurnCount = coveredCount
            Log.chat.notice("memory updated: covers \(coveredCount, privacy: .public) turns, facts=\(updated.durableFacts.count, privacy: .public) topics=\(updated.topicTrace.count, privacy: .public) chars")
            self.persist(session)   // memory/title changed — persist the source of truth
        }
    }

    /// Parse the model's `FACTS:` / `TOPICS:` output into the two-track memory. Robust by design — a
    /// 0.6B model will sometimes drop a label, reorder, or wrap the whole thing in prose. Fallback
    /// rules, in order of preference:
    ///   • Both labels present → split on them (this is the happy path).
    ///   • Only one label present → that section is parsed; the *other* track carries the prior value
    ///     forward (never silently emptied).
    ///   • No labels at all → treat the entire output as the new topic trace and PRESERVE prior durable
    ///     facts (facts are the protected track — we'd rather keep a slightly stale fact than lose it).
    /// Empty parsed sections fall back to the prior value for that track, so a cycle can only add or
    /// refine, never erase, what we already knew.
    nonisolated static func parseMemory(from output: String, prior: ConversationMemory) -> ConversationMemory {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return prior }

        // Case-insensitive search for the section labels at a line start (tolerant of "FACTS:" /
        // "Facts:" / leading whitespace).
        func labelRange(_ label: String) -> Range<String.Index>? {
            text.range(of: label, options: [.caseInsensitive])
        }
        let factsLabel = labelRange("FACTS:")
        let topicsLabel = labelRange("TOPICS:")

        func clean(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch (factsLabel, topicsLabel) {
        case let (.some(f), .some(t)) where f.upperBound <= t.lowerBound:
            // FACTS … TOPICS (expected order).
            let facts = clean(text[f.upperBound..<t.lowerBound])
            let topics = clean(text[t.upperBound...])
            return ConversationMemory(durableFacts: facts.isEmpty ? prior.durableFacts : facts,
                                      topicTrace: topics.isEmpty ? prior.topicTrace : topics)
        case let (.some(f), .some(t)):
            // TOPICS … FACTS (reordered).
            let topics = clean(text[t.upperBound..<f.lowerBound])
            let facts = clean(text[f.upperBound...])
            return ConversationMemory(durableFacts: facts.isEmpty ? prior.durableFacts : facts,
                                      topicTrace: topics.isEmpty ? prior.topicTrace : topics)
        case let (.some(f), .none):
            let facts = clean(text[f.upperBound...])
            return ConversationMemory(durableFacts: facts.isEmpty ? prior.durableFacts : facts,
                                      topicTrace: prior.topicTrace)
        case let (.none, .some(t)):
            let topics = clean(text[t.upperBound...])
            return ConversationMemory(durableFacts: prior.durableFacts,
                                      topicTrace: topics.isEmpty ? prior.topicTrace : topics)
        case (.none, .none):
            // No structure at all — treat as topic notes, keep prior facts protected.
            return ConversationMemory(durableFacts: prior.durableFacts, topicTrace: text)
        }
    }

    /// Extract the `TITLE:` line the summarizer emits (kept separate from the FACTS/TOPICS memory).
    private static func parseTitle(from output: String) -> String? {
        guard let r = output.range(of: "TITLE:", options: .caseInsensitive) else { return nil }
        let line = output[r.upperBound...].prefix(while: { !$0.isNewline })
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        return title.isEmpty ? nil : String(title.prefix(42))
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

    /// Tight summarization instruction: evolve the two-track memory with the new exchanges. Emits a
    /// strict two-section contract (FACTS / TOPICS) so the parser is reliable even on a 0.6B model.
    /// Deliberately small and concrete — a tiny model can follow it.
    private static func summarizationPrompt(prior: ConversationMemory, newTranscript: String) -> String {
        let priorFacts = prior.durableFacts.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorTopics = prior.topicTrace.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorBlock = (priorFacts.isEmpty && priorTopics.isEmpty)
            ? "There is no earlier memory yet."
            : """
            Current FACTS so far:
            \(priorFacts.isEmpty ? "(none yet)" : priorFacts)

            Current TOPICS so far:
            \(priorTopics.isEmpty ? "(none yet)" : priorTopics)
            """
        return """
        You maintain a compact memory of an ongoing chat so a later assistant stays coherent without \
        the full history. Fold the new exchanges below into the memory and output it in exactly this \
        format, with these labels and nothing else:

        TITLE: <a 2–5 word name for this whole conversation, no quotes>
        FACTS:
        - <one durable fact per line>
        TOPICS:
        <running notes on what's been discussed>

        FACTS = stable facts about the user and their goal: their name, role, what they're building, \
        and standing preferences or constraints. Carry every prior fact forward, add any new durable \
        ones, merge duplicates, and drop nothing important. No greetings or filler. Keep it short — \
        well under 150 words; if it grows too long, merge and prune wording, never drop a real fact.

        TOPICS = what has been discussed. Keep the CURRENT topic detailed; condense each OLDER topic \
        to a single short line so the notes shrink over time instead of piling up — but always leave a \
        thin trace of every past topic so earlier points can still be referenced. Under 200 words.

        Output ONLY those sections — no preamble, no "here is", no markdown headings beyond the \
        TITLE:/FACTS:/TOPICS: labels.

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
        scheduleIndex()
        persist(active)   // a completed turn is the main state change worth saving
    }

    // MARK: - Semantic memory index (background)

    /// Embed newly-completed exchanges into the in-session memory index — off the send path, so it
    /// never blocks a reply. Incremental (only new exchanges are embedded).
    private func scheduleIndex() {
        // Capture the session so indexing commits to the conversation it belongs to, even after a switch.
        let session = active
        let exchanges = Self.exchanges(from: session.messages)
        guard !exchanges.isEmpty else { return }
        session.indexTask?.cancel()
        session.indexTask = Task { await session.memoryIndex.index(exchanges) }
    }

    /// Pair the visible conversation into (user + assistant) exchanges — the retrieval unit, so a
    /// recalled answer always carries its question. Uses the exact text the model saw (`promptText`),
    /// `<think>` stripped; skips unfinished / errored assistant turns.
    private static func exchanges(from messages: [ChatMessage]) -> [ChatMemoryIndex.Exchange] {
        var out: [ChatMemoryIndex.Exchange] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            if m.role == .user, i + 1 < messages.count, messages[i + 1].role == .assistant {
                let a = messages[i + 1]
                if a.isStreaming || a.isError { i += 1; continue }
                let userText = m.promptText ?? m.text
                let asstText = stripThoughtBlocks(from: a.text)
                out.append(.init(messageIDs: [m.id, a.id],
                                 text: "User: \(userText)\nAssistant: \(asstText)"))
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// Retrieve relevant older exchanges for this turn. Query = the current (folded) user text plus the
    /// last couple of turns, so a follow-up like "continue debugging the parser" still matches the
    /// earlier parser thread. Excludes anything already in the recent verbatim window (no duplicates).
    private func retrieveMemory(currentUserText: String) async -> [String] {
        let history = messages.dropLast(2)                       // drop the just-appended user+placeholder
        guard !history.isEmpty else { return [] }
        let recentWindow = history.suffix(contextBuilder.budget.recentTurns)
        let recentIDs = Set(recentWindow.map(\.id))
        let recentContext = history.suffix(2).map { $0.promptText ?? $0.text }
        // Question = the explicit current text (primary signal); context adds the last couple of turns
        // so pronoun-y follow-ups ("continue that") still match, without diluting an explicit question.
        let context = (recentContext + [currentUserText]).joined(separator: "\n")
        return await memoryIndex.retrieve(question: currentUserText, context: context, excluding: recentIDs)
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
