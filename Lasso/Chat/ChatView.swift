import SwiftUI

/// The Chat panel UI: a scrollable conversation with a composer. Renders `ChatController.shared`.
struct ChatView: View {
    @Bindable private var chat = ChatController.shared
    private let intelligence = IntelligenceCoordinator.shared
    @AppStorage("ui.resultTextScale") private var textScale = 1.0
    @FocusState private var inputFocused: Bool
    @State private var isDropTarget = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(isDropTarget ? Color.accentColor : .white.opacity(0.10),
                          lineWidth: isDropTarget ? 2 : 1))
        .onAppear { DispatchQueue.main.async { inputFocused = true } }
        // Drag-and-drop an image (from Finder or another app) onto the panel to attach it.
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard chat.imageInputAvailable else { return false }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) })
            ?? providers.first else { return false }
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Task { @MainActor in chat.attach(cg) }
        }
        return true
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lasso").foregroundStyle(.tint)
            conversationsMenu
            Spacer()
            modelChip
            Button { ChatPanelController.shared.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Close — ⌥⌘A or Esc")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Drag the window by its header (the panel is no longer movable-by-background, so body
        // controls stay clickable). Sits behind the buttons, which capture their own clicks.
        .background(WindowDragArea())
    }

    /// Title of the active conversation + a menu to switch between open conversations or start a new
    /// one — so "Continue in chat" / selection threads no longer replace the chat you were in.
    private var conversationsMenu: some View {
        Menu {
            ForEach(chat.sessionSummaries, id: \.id) { s in
                Button {
                    chat.switchTo(s.id); inputFocused = true
                } label: {
                    Label(s.title, systemImage: s.isActive ? "checkmark" : s.systemImage)
                }
                .disabled(s.isActive || chat.active.isStreaming)
            }
            Divider()
            Button { chat.newChat(); inputFocused = true } label: {
                Label("New conversation", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) { chat.closeActive(); inputFocused = true } label: {
                Label("Close this conversation", systemImage: "trash")
            }
            .disabled(chat.active.isStreaming || (chat.sessions.count == 1 && !chat.canClear))
        } label: {
            HStack(spacing: 3) {
                Text(chat.sessions.count > 1 ? chat.active.title : "Chat")
                    .font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Conversations — switch or start a new one")
    }

    /// Compact model indicator that doubles as a quick switcher — pick any model you've already set
    /// up (no keys/downloads here; that stays in Settings). Switching applies globally.
    private var modelChip: some View {
        Menu {
            Section("Language model") {
                Button { chat.selectTextModel(.onDevice) } label: {
                    Label("Apple Intelligence",
                          systemImage: chat.isCurrentTextModel(.onDevice) ? "checkmark" : "cpu")
                }
                if !chat.ollamaModels.isEmpty {
                    Menu("Ollama") {
                        ForEach(chat.ollamaModels, id: \.self) { m in
                            Button { chat.selectTextModel(.ollama, model: m) } label: {
                                if chat.isCurrentTextModel(.ollama, model: m) {
                                    Label(m, systemImage: "checkmark")
                                } else { Text(m) }
                            }
                        }
                    }
                }
                let mlx = chat.mlxModels
                if !mlx.isEmpty {
                    Menu("MLX") {
                        ForEach(mlx, id: \.id) { item in
                            Button { chat.selectTextModel(.mlx, model: item.id) } label: {
                                if chat.isCurrentTextModel(.mlx, model: item.id) {
                                    Label(item.label, systemImage: "checkmark")
                                } else { Text(item.label) }
                            }
                        }
                    }
                }
                ForEach(chat.openAIServices, id: \.service) { svc in
                    Button { chat.selectOpenAIService(svc.service) } label: {
                        Label("\(svc.name) · \(Self.shortModel(svc.model))",
                              systemImage: chat.isCurrentOpenAIService(svc.service) ? "checkmark" : "cloud")
                    }
                }
                if chat.anthropicReady {
                    Button { chat.selectTextModel(.anthropic) } label: {
                        Label("Anthropic · \(intelligence.anthropicModel)",
                              systemImage: chat.isCurrentTextModel(.anthropic) ? "checkmark" : "cloud")
                    }
                }
            }
            if chat.imageInputAvailable {
                Section("Image model") {
                    Text(Self.shortModel(intelligence.imageEngineLabel))   // read-only — change in Settings
                }
            }
            Divider()
            Label(intelligence.privacyNote,
                  systemImage: intelligence.usedOffDeviceThisSession ? "cloud" : "lock.fill")
            Button("Open Intelligence Settings…") { openSettings() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: textIcon).font(.system(size: 9))
                Text(Self.shortModel(intelligence.textEngineLabel))
                    .font(.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch model")
    }

    /// "Groq · openai/gpt-oss-20b" → "gpt-oss-20b" for the compact chip.
    private static func shortModel(_ label: String) -> String {
        let afterDot = label.components(separatedBy: " · ").last ?? label
        return afterDot.components(separatedBy: "/").last ?? afterDot
    }

    // MARK: - Conversation

    @ViewBuilder
    private var conversation: some View {
        if chat.messages.isEmpty {
            // Empty state lives outside the ScrollView — both for a cleaner layout and because
            // controls inside the scroll view weren't reliably receiving clicks.
            emptyState
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // NOTE: `.defaultScrollAnchor(.bottom)` was removed — it offsets hit-testing from what's
            // drawn (clicks on the Activity row landed on whatever element was at that point in the
            // un-adjusted layout, e.g. a source link), which is why controls inside the scroll view
            // "weren't reliably receiving clicks." Auto-scroll is done explicitly via ScrollViewReader,
            // keyed to data changes (not geometry) so it doesn't loop.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message, fontSize: resultTextBaseSize * textScale)
                        }
                        if chat.trimmedNotice {
                            Label("Earlier messages were trimmed to fit the model's context.",
                                  systemImage: "scissors")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        Color.clear.frame(height: 1).id(Self.scrollBottomID)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(Self.scrollBottomID, anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
        }
    }

    private static let scrollBottomID = "chat-bottom"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How can I help?")
                .font(.title2).fontWeight(.semibold)
            Text("Chat with \(engineName) — private, on your Mac unless you pick a cloud model.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions) { suggestion in
                    Button {
                        chat.send(text: suggestion.title, extraContext: suggestion.context,
                                  webSearch: suggestion.webSearch)
                    } label: {
                        Text(suggestion.title)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))   // make the whole chip tappable
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    /// A starter chip. `context` is one-shot context folded into that question only — e.g. the
    /// "What can you do?" chip injects Lasso's real feature list so the answer is grounded.
    private struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        var context: String?
        /// Per-chip web-grounding override (nil = follow the user's globe toggle).
        var webSearch: Bool?
    }

    private static let suggestions: [Suggestion] = [
        // Canned starter prompts — grounded by the model alone (web search just adds noise here).
        Suggestion(title: "What can you do?", context: ChatController.lassoCapabilities, webSearch: false),
        Suggestion(title: "Help me write a short, friendly email", webSearch: false),
        Suggestion(title: "Explain a tricky concept in simple terms", webSearch: false),
    ]

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            // Seeded capture context + pending image attachment chips.
            if chat.seededContext != nil || !chat.pendingAttachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chat.pendingAttachments) { att in
                        ZStack(alignment: .topTrailing) {
                            Image(decorative: att.image, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button { chat.removeAttachment(att.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption)
                            }
                            .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.5))
                            .offset(x: 4, y: -4)
                        }
                    }
                    if let context = chat.seededContext {
                        contextChip(context)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { attachImage() } label: { Image(systemName: "photo.badge.plus") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!chat.imageInputAvailable)
                    .help(chat.imageInputAvailable
                          ? "Attach an image — or paste (⌘V) or drag one onto the panel"
                          : "Attach an image — needs a multimodal or Image model (Settings ▸ Intelligence)")

                if chat.webConnectorsAvailable {
                    Button { chat.webSearchOn.toggle() } label: { Image(systemName: "globe") }
                        .buttonStyle(IconButtonStyle())
                        .foregroundStyle(chat.webSearchOn ? Color.accentColor : Color.secondary)
                        .help(chat.webSearchOn
                              ? "Web grounding ON — answers use your connectors (Wikipedia, search, reverse-image)"
                              : "Web grounding OFF — tap to ground answers with your connectors")
                }

                TextField("Message…", text: Binding(
                    get: { chat.active.input }, set: { chat.active.input = $0 }))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($inputFocused)
                    .onSubmit { chat.send() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.1)))

                if chat.isStreaming {
                    Button { chat.cancelStreaming() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(IconButtonStyle()).help("Stop")
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                        .disabled(!canSend)
                        .help("Send")
                }
            }
        }
        .padding(12)
    }

    private func contextChip(_ context: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.viewfinder").font(.caption)
            Text(context).lineLimit(1).truncationMode(.tail).font(.caption)
            Button { chat.clearSeededContext() } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.tint.opacity(0.18), in: Capsule())
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var canSend: Bool {
        !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingAttachments.isEmpty
    }

    private var engineName: String {
        intelligence.lastProviderName.isEmpty ? intelligence.effectivePreferred.label
            : intelligence.lastProviderName
    }
    /// Locality icon (cpu = Apple on-device, cloud = remote, server.rack = any local backend).
    private var textIcon: String {
        switch intelligence.effectivePreferred {
        case .onDevice: "cpu"
        case .openAICompatible, .anthropic: "cloud"
        default: "server.rack"   // ollama / other local backends
        }
    }
    private var imageIcon: String {
        switch intelligence.effectiveVisionEngine {
        case .matchText: textIcon
        case .openAICompatible, .anthropic: "cloud"
        default: "server.rack"
        }
    }

    private func attachImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                chat.attach(image)
            }
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let fontSize: CGFloat

    private var isUser: Bool { message.role == .user }

    private var hasTrace: Bool { !message.steps.isEmpty || !message.reasoning.isEmpty }

    @State private var copied = false

    /// Replaces drag-to-select on assistant answers (which stole clicks from the Activity row).
    private var copyButton: some View {
        Button {
            Pasteboard.copy(message.text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Copy this answer")
    }

    var body: some View {
        // User messages: a right-aligned tinted bubble (kept narrow). Assistant messages: full-width
        // with no bubble (ChatGPT/Claude style) so tables, code, and long text get the whole panel.
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                if message.attachments.count == 1, let att = message.attachments.first {
                    Image(decorative: att.image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { att in
                            Image(decorative: att.image, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !isUser, hasTrace {
                    TraceView(message: message)
                }
                if message.isStreaming && message.text.isEmpty && !hasTrace {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !message.text.isEmpty {
                    // Not drag-selectable: selectable text in the scroll view intercepts clicks meant for the
                    // Activity disclosure. A Copy button replaces highlight-to-copy on assistant turns.
                    MarkdownView(text: message.text, fontSize: fontSize, selectable: false)
                        .foregroundStyle(message.isError ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isUser, !message.isStreaming, !message.isError {
                        copyButton
                    }
                }
            }
            .padding(.horizontal, isUser ? 11 : 2).padding(.vertical, isUser ? 8 : 2)
            .background(isUser ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

}

// MARK: - Activity trace ("Thought for Xs" + steps)

/// Collapsible record of what the assistant did for a turn — model reasoning (from `<think>`) and the
/// pipeline steps (looked at image, searched the web, pages it read). Auto-expands while the turn is
/// running so progress is visible live, then collapses to a one-line summary.
private struct TraceView: View {
    let message: ChatMessage
    @State private var expanded = true

    private var summary: String {
        if message.isStreaming {
            return message.steps.last(where: { !$0.done })?.text
                ?? (message.reasoning.isEmpty ? "Working…" : "Thinking…")
        }
        if let secs = message.reasoningSeconds { return "Thought for \(secs)s" }
        if !message.reasoning.isEmpty { return "Thought process" }
        return "Activity"
    }

    var body: some View {
        // Use a DisclosureGroup (not a custom Button toggling @State) — the same control the model's
        // "Thought" section uses, which toggles reliably inside the chat ScrollView where a plain
        // Button's click was being missed.
        DisclosureGroup(isExpanded: $expanded) {
            // Vertical rail with a checkpoint dot per item (reasoning first, then steps).
            VStack(alignment: .leading, spacing: 10) {
                if !message.reasoning.isEmpty {
                    timelineItem(done: !message.isStreaming) {
                        Text(message.reasoning)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(message.steps) { step in
                    timelineItem(done: step.done) { stepContent(step) }
                }
            }
            .padding(.top, 2)
            .background(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.25))
                    .frame(width: 1)
                    .padding(.leading, 2)      // centered under the 5px dots
                    .padding(.vertical, 6)
            }
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if message.isStreaming { ProgressView().controlSize(.small) }
                else { Image(systemName: "sparkles").font(.caption2) }
                Text(summary).font(.caption).fontWeight(.medium)
            }
            .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
        .onChange(of: message.isStreaming) { _, streaming in
            if !streaming { withAnimation(.easeOut(duration: 0.2)) { expanded = false } }
        }
    }

    @ViewBuilder
    private func timelineItem<Content: View>(done: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(done ? Color.green.opacity(0.8) : Color.secondary.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, 5)   // align the dot with the first text line
            content()
        }
    }

    @ViewBuilder
    private func stepContent(_ step: ActivityStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(step.text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(step.links) { hit in
                if let url = hit.url {
                    Link(destination: url) {
                        Label(hit.title, systemImage: "link")
                            .font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Window drag region

/// A transparent AppKit view that drags its window on mouse-down. Used as the header background so
/// the panel can be moved without making the whole window movable-by-background (which would intercept
/// clicks meant for SwiftUI controls).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
