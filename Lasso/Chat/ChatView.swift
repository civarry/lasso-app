import SwiftUI

/// The Chat panel UI: a scrollable conversation with a composer. Renders `ChatController.shared`.
struct ChatView: View {
    @Bindable private var chat = ChatController.shared
    private let intelligence = IntelligenceCoordinator.shared
    @AppStorage("ui.resultTextScale") private var textScale = 1.0
    @FocusState private var inputFocused: Bool
    @State private var isDropTarget = false
    @State private var showModelInfo = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(isDropTarget ? Color.accentColor : .white.opacity(0.10),
                          lineWidth: isDropTarget ? 2 : 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
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
            Text("Chat").font(.headline)
            Spacer()
            modelChip
            Button { chat.newChat(); inputFocused = true } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("New chat — clears the conversation")
            .disabled(!chat.canClear)

            Button { ChatPanelController.shared.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Close — ⌥⌘A or Esc")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Compact model indicator in the header; opens a popover with full Text/Image/privacy details.
    private var modelChip: some View {
        Button { showModelInfo.toggle() } label: {
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
        .buttonStyle(.plain)
        .help("Models & privacy")
        .popover(isPresented: $showModelInfo, arrowEdge: .bottom) { modelInfoPopover }
    }

    private var modelInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models").font(.headline)
            Label { Text("Text · \(intelligence.textEngineLabel)") } icon: {
                Image(systemName: textIcon)
            }
            if chat.imageInputAvailable {
                Label { Text("Image · \(intelligence.imageEngineLabel)") } icon: {
                    Image(systemName: imageIcon)
                }
            }
            Divider()
            Label {
                Text(intelligence.privacyNote)
            } icon: {
                Image(systemName: intelligence.usedOffDeviceThisSession ? "cloud" : "lock.fill")
            }
            .foregroundStyle(.secondary)
            Text("Change models in Settings ▸ Intelligence.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    /// "Groq · openai/gpt-oss-20b" → "gpt-oss-20b" for the compact chip.
    private static func shortModel(_ label: String) -> String {
        let afterDot = label.components(separatedBy: " · ").last ?? label
        return afterDot.components(separatedBy: "/").last ?? afterDot
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.messages.isEmpty { emptyState }
                ForEach(chat.messages) { message in
                    MessageBubble(message: message, fontSize: resultTextBaseSize * textScale)
                }
                if chat.trimmedNotice {
                    Label("Earlier messages were trimmed to fit the model's context.",
                          systemImage: "scissors")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Auto-pins to the bottom as content grows — no manual scrollTo (which caused a layout loop).
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How can I help?")
                .font(.title2).fontWeight(.semibold)
            Text("Chat with \(engineName) — private, on your Mac unless you pick a cloud model.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button { chat.input = suggestion; chat.send() } label: {
                        Text(suggestion)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private static let suggestions = [
        "What can you do?",
        "Help me write a short, friendly email",
        "Explain a tricky concept in simple terms",
    ]

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            // Seeded capture context + pending image attachment chips.
            if chat.seededContext != nil || chat.pendingImage != nil {
                HStack(spacing: 8) {
                    if let image = chat.pendingImage {
                        ZStack(alignment: .topTrailing) {
                            Image(decorative: image, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button { chat.clearAttachment() } label: {
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

                TextField("Message…", text: $chat.input)
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
        !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.pendingImage != nil
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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            chat.attach(image)
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let fontSize: CGFloat

    private var isUser: Bool { message.role == .user }

    private var hasTrace: Bool { !message.steps.isEmpty || !message.reasoning.isEmpty }

    var body: some View {
        // User messages: a right-aligned tinted bubble (kept narrow). Assistant messages: full-width
        // with no bubble (ChatGPT/Claude style) so tables, code, and long text get the whole panel.
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                if let image = message.image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    MarkdownView(text: message.text, fontSize: fontSize)
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if message.isStreaming { ProgressView().controlSize(.small) }
                    else { Image(systemName: "sparkles").font(.caption2) }
                    Text(summary).font(.caption).fontWeight(.medium)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.reasoning.isEmpty {
                        Text(message.reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(message.steps) { step in
                        stepRow(step)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
        .onChange(of: message.isStreaming) { _, streaming in
            if !streaming { withAnimation(.easeOut(duration: 0.2)) { expanded = false } }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: ActivityStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: step.done ? "checkmark.circle.fill" : step.icon)
                    .font(.caption2)
                    .foregroundStyle(step.done ? Color.green.opacity(0.8) : .secondary)
                Text(step.text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(step.links) { hit in
                if let url = hit.url {
                    Link(destination: url) {
                        Label(hit.title, systemImage: "link")
                            .font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.leading, 18)
                }
            }
        }
    }
}
