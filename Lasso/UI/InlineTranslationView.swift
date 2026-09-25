import SwiftUI
import Translation

/// Google-style "translate in place": draws an opaque plate over each block of text in the selection
/// with its translation inside, plus a source → target language bar (Spec §9, docs/TRANSLATE_LLM.md).
///
/// Two passes. Pass 1 is Apple's Translation framework, on-device and near-instant; it runs one
/// session per source language, because each block carries its own detected language (a selection
/// with English and Japanese translates both). Pass 2 sends the whole selection to the user's text
/// model and swaps each block in as its line arrives; any block it misses keeps pass 1's text.
///
/// Closing is routed through `CaptureCoordinator.shared` (not a stored closure) so this view stays
/// `Sendable` — required because the `.translationTask` work runs in a `@Sendable` closure.
struct InlineTranslationView: View {
    let lines: [OCRLine]
    /// Selection rectangle in this view's point coordinates (top-left origin).
    let selectionRect: CGRect
    /// The captured crop, sampled for plate colours.
    let image: CGImage?

    /// Where the model pass stands, for the language bar.
    private enum ModelPass: Equatable {
        case idle
        case running
        case improved(model: String)
        /// The model pass failed or returned nothing usable. Pass 1 stays; the bar says so quietly.
        case failed(reason: String)
    }

    private struct PlateStyle {
        var fill: Color
        var text: Color
        static let dark = PlateStyle(fill: Color(white: 0.11), text: .white)
    }

    @State private var blocks: [TextBlock] = []
    /// nil until detection has run: the only time the source chip may read "Detecting…".
    @State private var detected: [Locale.Language]?
    @State private var pass1: [UUID: String] = [:]
    @State private var llm: [UUID: String] = [:]
    /// Source languages still waiting for a pass-1 session, and the one running now.
    @State private var pass1Queue: [Locale.Language] = []
    @State private var pass1Source: Locale.Language?
    @State private var pass1Done = false
    @State private var pass1Started = Date()
    @State private var pass1Duration: TimeInterval?
    /// Bumped on every restart, so a session cancelled by a language change can't advance the new queue.
    @State private var generation = 0
    @State private var modelPass: ModelPass = .idle
    @State private var modelTask: Task<Void, Never>?
    /// Model results by (block ids, target, source override), so toggling views never re-runs it.
    @State private var modelCache: [String: (model: String, texts: [UUID: String])] = [:]
    @State private var plateStyles: [UUID: PlateStyle] = [:]
    @State private var config: TranslationSession.Configuration?
    @State private var sourceOverride: Locale.Language?
    @State private var showOriginal = false
    @State private var peeking = false
    @State private var readingMode = false
    @State private var sideBySide = false
    @State private var copied = false
    @AppStorage("ui.resultTextScale") private var textScale = 1.0
    @State private var target: Locale.Language =
        Locale.Language(identifier: Locale.current.language.languageCode?.identifier ?? "en")

    private let languageChoices: [Locale.Language] = [
        "en", "zh-Hant", "zh-Hans", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "th",
    ].map(Locale.Language.init(identifier:))

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            if readingMode {
                readingPanel(in: geo.size)
            } else {
                // Hold anywhere in the selection to peek at the original.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in peeking = true }
                        .onEnded { _ in peeking = false })
                if !showOriginal && !peeking {
                    plates
                }
            }

            languageBar.position(barPoint(in: geo.size))
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .task { start() }
        .onDisappear { modelTask?.cancel() }
        .onChange(of: target) { _, _ in restart() }
        .onChange(of: sourceOverride) { _, _ in restart() }
        .translationTask(config) { @Sendable session in
            let work = await MainActor.run { pass1Work() }
            guard let work else { return }
            do {
                try await BlockTranslationPass.run(work.blocks, session: session) { ids, text in
                    await MainActor.run {
                        guard generation == work.generation else { return }
                        for id in ids { pass1[id] = text }
                    }
                }
            } catch {
                Log.app.error("Translate batch failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                guard generation == work.generation, !Task.isCancelled else { return }
                advancePass1()
            }
        }
        }
    }

    // MARK: - Overlay

    private var plates: some View {
        let layout = PlateLayout.layout(plateInputs, bounds: selectionRect, measure: PlateLayout.appKitMeasure)
        return ForEach(layout, id: \.id) { plate in
            let style = plateStyles[plate.id] ?? .dark
            if let text = plate.text {
                Text(text)
                    .font(.system(size: plate.fontSize, weight: .medium))
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(style.text)
                    .padding(.horizontal, PlateLayout.padding.width)
                    .padding(.vertical, PlateLayout.padding.height)
                    .frame(width: plate.rect.width, height: plate.rect.height, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
                    .overlay {
                        // A sweep across every block the model hasn't reached yet, so the overlay
                        // itself shows the AI pass is working; it stops as each block swaps in.
                        if modelPass == .running, llm[plate.id] == nil {
                            Shimmer(tint: style.text.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .transition(.opacity)
                        }
                    }
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: text)
                    .position(x: plate.rect.midX, y: plate.rect.midY)
                    .allowsHitTesting(false)
            } else {
                // Skeleton until pass 1 reaches this block.
                RoundedRectangle(cornerRadius: 4)
                    .fill(style.fill.opacity(0.9))
                    .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 4)))
                    .frame(width: plate.rect.width, height: plate.rect.height)
                    .position(x: plate.rect.midX, y: plate.rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var plateInputs: [PlateLayout.Input] {
        blocks.map { block in
            let content: PlateLayout.Content
            if !needsTranslation(block) {
                content = .untranslated
            } else if let text = displayText(block) {
                content = .text(text)
            } else {
                // Pass 1 finished without this block (its session failed): show the original rather
                // than a skeleton that never resolves.
                content = pass1Done ? .untranslated : .pending
            }
            return PlateLayout.Input(id: block.id, frame: viewRect(for: block.frame),
                                     lineCount: block.lineIDs.count, content: content)
        }
    }

    // MARK: - Reading view

    /// Clean, scrollable reading view: one paragraph per block, optionally beside its original.
    /// Anchored to the language bar (below it, flipping above when there's no room), aligned
    /// horizontally with it, so it matches the Summarize / Ask AI result-pane pattern.
    private func readingPanel(in size: CGSize) -> some View {
        let panelWidth = min(sideBySide ? 760 : 540, size.width - 48)
        let panelHeight = min(size.height * 0.5, 420)
        let bar = barPoint(in: size)
        let barHalf: CGFloat = 26
        let gap: CGFloat = 12

        let belowCenter = bar.y + barHalf + gap + panelHeight / 2
        let aboveCenter = bar.y - barHalf - gap - panelHeight / 2
        let centerY: CGFloat
        if belowCenter + panelHeight / 2 + 12 <= size.height {
            centerY = belowCenter
        } else if aboveCenter - panelHeight / 2 >= 12 {
            centerY = aboveCenter
        } else {
            centerY = size.height / 2
        }
        let minX = panelWidth / 2 + 12
        let maxX = size.width - panelWidth / 2 - 12
        let centerX = maxX < minX ? size.width / 2 : min(max(bar.x, minX), maxX)
        let fontSize = resultTextBaseSize * textScale

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $sideBySide) {
                    Text("Translation").tag(false)
                    Text("Side by side").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextScaleControls(scale: $textScale)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize) {
                    ForEach(blocks) { block in
                        if sideBySide {
                            HStack(alignment: .top, spacing: 16) {
                                Text(block.text)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                readingParagraph(block)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            readingParagraph(block)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: fontSize))
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(readingText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(readingText.isEmpty)
                .help("Copy the whole translation")
            }
        }
        .padding(16)
        .frame(width: panelWidth, height: panelHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .position(x: centerX, y: centerY)
    }

    /// A block in the target language: its translation, its own text when it needed none, or the
    /// original dimmed while pass 1 is still on its way.
    @ViewBuilder
    private func readingParagraph(_ block: TextBlock) -> some View {
        if let text = readingText(for: block) {
            Text(text)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: text)
        } else {
            Text(block.text).foregroundStyle(.tertiary)
        }
    }

    private func readingText(for block: TextBlock) -> String? {
        needsTranslation(block) ? displayText(block) : block.text
    }

    private var readingText: String {
        TranslationPlan.readingText(blocks) { readingText(for: $0) }
    }

    /// "English, Chinese → Chinese (Taiwan)": what was found and what it became.
    private var summaryLine: String {
        let from = sourceOverride.map { [displayName($0)] } ?? (detected ?? []).map(displayName)
        return "\(from.isEmpty ? "Unknown source" : from.joined(separator: ", ")) → \(displayName(target))"
    }

    // MARK: - Language bar

    /// Center point for the language bar: just below the selection, flipped above if there's no
    /// room, and clamped horizontally so the bar stays on screen.
    private func barPoint(in size: CGSize) -> CGPoint {
        let gap: CGFloat = 16, halfHeight: CGFloat = 24, halfWidth: CGFloat = 300, margin: CGFloat = 16
        let belowY = selectionRect.maxY + gap + halfHeight
        let aboveY = selectionRect.minY - gap - halfHeight
        let y = (belowY + halfHeight + margin <= size.height) ? belowY : max(margin + halfHeight, aboveY)
        let minX = margin + halfWidth, maxX = size.width - margin - halfWidth
        let x = maxX < minX ? size.width / 2 : min(max(selectionRect.midX, minX), maxX)
        let drag = CaptureCoordinator.shared.panelDragOffset
        return CGPoint(x: x + drag.width, y: y + drag.height)
    }

    private var languageBar: some View {
        HStack(spacing: 10) {
            DragHandle(coordinator: CaptureCoordinator.shared)

            languageMenu(
                title: TranslationPlan.sourceLabel(detected: detected, override: sourceOverride,
                                                   name: displayName),
                selection: { sourceOverride = $0 },
                includeAuto: true
            )

            Button {
                // Swap source/target.
                if let current = swapSource {
                    sourceOverride = target
                    target = current
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(swapSource == nil)
            .help("Swap languages")

            languageMenu(
                title: displayName(target),
                selection: { if let l = $0 { target = l } },
                includeAuto: false
            )

            Divider().frame(height: 18)
            engineStatus

            Divider().frame(height: 18)

            Button { readingMode.toggle() } label: {
                Image(systemName: readingMode ? "rectangle.on.rectangle" : "list.bullet.rectangle")
            }
            .buttonStyle(IconButtonStyle())
            .help(readingMode ? "Overlay view" : "Reading view")

            if !readingMode {
                Button { showOriginal.toggle() } label: {
                    Image(systemName: showOriginal ? "eye.slash" : "eye")
                }
                .buttonStyle(IconButtonStyle())
                .help(showOriginal ? "Show translation" : "Show original (or press and hold the selection)")
            }

            Button { CaptureCoordinator.shared.exitTranslate() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .help("Done")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    /// Which engine answered: pass 1's progress, then "On-device", then "Improved · <model>".
    @ViewBuilder
    private var engineStatus: some View {
        let translatable = blocks.filter(needsTranslation)
        if detected != nil, translatable.isEmpty {
            Text("Already in \(displayName(target))")
                .font(.caption).foregroundStyle(.primary)
        } else if !pass1Done {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(translatable.filter { pass1[$0.id] != nil }.count)/\(translatable.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.primary)
            }
        } else {
            switch modelPass {
            case .running:
                let done = translatable.filter { llm[$0.id] != nil }.count
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(done == 0 ? "Improving…" : "Improving \(done)/\(translatable.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.primary)
                }
                .help("Retranslating with \(IntelligenceCoordinator.shared.textEngineLabel)")
            case .improved(let model):
                // The model name can be long ("OpenRouter · nvidia/…:free"), so it lives in the tooltip.
                Label("Improved", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.primary)
                    .help("Improved by \(model). Blocks it missed keep the on-device translation.")
            case .idle, .failed:
                HStack(spacing: 4) {
                    Label("On-device · \(translatable.count) \(translatable.count == 1 ? "block" : "blocks")",
                          systemImage: "cpu")
                        .font(.caption).monospacedDigit().foregroundStyle(.primary)
                        .help(pass1Duration.map { String(format: "Apple Translation, %.2fs", $0) } ?? "Apple Translation")
                    if case .failed(let reason) = modelPass, modelAvailable {
                        Button { startModelPass() } label: {
                            Image(systemName: "sparkles").foregroundStyle(.orange)
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("AI pass failed: \(reason)\nShowing the on-device translation. Click to try again.")
                    } else if LLMTranslation.Mode.current == .ask, modelAvailable {
                        Button { startModelPass() } label: {
                            Image(systemName: "sparkles")
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("Improve with AI: retranslate the whole selection with \(IntelligenceCoordinator.shared.textEngineLabel), using the surrounding text as context.")
                    }
                }
            }
        }
    }

    private var swapSource: Locale.Language? {
        sourceOverride ?? (detected ?? []).first { TranslationPlan.base($0) != TranslationPlan.base(target) }
    }

    private func languageMenu(title: String,
                              selection: @escaping (Locale.Language?) -> Void,
                              includeAuto: Bool) -> some View {
        Menu {
            if includeAuto {
                Button("Auto-detect") { selection(nil) }
                Divider()
            }
            ForEach(languageChoices, id: \.self) { lang in
                Button(displayName(lang)) { selection(lang) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Pass 1

    private func needsTranslation(_ block: TextBlock) -> Bool {
        TranslationPlan.needsTranslation(block, target: target, override: sourceOverride)
    }

    private func displayText(_ block: TextBlock) -> String? {
        LLMTranslation.display(pass1: pass1[block.id], llm: llm[block.id])
    }

    private func start() {
        blocks = TextBlocks.group(lines)
        detected = TranslationPlan.detectedLanguages(blocks, name: displayName)
        samplePlateColors()
        // Reuse the background pre-translation (pass 1 only) for whatever blocks it covered.
        let shared = CaptureCoordinator.shared
        if sourceOverride == nil, shared.pretranslatedTarget == target {
            pass1 = shared.pretranslated
        }
        restart(keepingPass1: true)
    }

    /// (Re)run pass 1 for every source language, then the model pass per the setting.
    private func restart(keepingPass1: Bool = false) {
        generation += 1
        modelTask?.cancel()
        modelTask = nil
        if !keepingPass1 { pass1 = [:] }
        pass1Done = false
        pass1Duration = nil
        pass1Started = Date()

        let groups = TranslationPlan.groups(blocks, target: target, override: sourceOverride)
        pass1Queue = groups.filter { $0.blocks.contains { pass1[$0.id] == nil } }.map(\.source)
        advancePass1()

        if let cached = modelCache[modelCacheKey] {
            llm = cached.texts
            modelPass = .improved(model: cached.model)
        } else {
            llm = [:]
            modelPass = .idle
            if LLMTranslation.Mode.current == .always, modelAvailable { startModelPass() }
        }
    }

    private func advancePass1() {
        guard !pass1Queue.isEmpty else {
            pass1Source = nil
            pass1Done = true
            pass1Duration = Date().timeIntervalSince(pass1Started)
            return
        }
        let source = pass1Queue.removeFirst()
        pass1Source = source
        let next = TranslationSession.Configuration(source: source, target: target)
        if config == next { config?.invalidate() } else { config = next }
    }

    /// The blocks the running pass-1 session should translate, tagged with the generation it's for.
    private func pass1Work() -> (blocks: [TextBlock], generation: Int)? {
        guard let source = pass1Source else { return nil }
        let work = blocks.filter {
            needsTranslation($0) && pass1[$0.id] == nil
                && TranslationPlan.source(of: $0, override: sourceOverride)?.minimalIdentifier == source.minimalIdentifier
        }
        return (work, generation)
    }

    // MARK: - Pass 2 (model)

    private var modelAvailable: Bool {
        LLMTranslation.Mode.current != .off
            && IntelligenceCoordinator.shared.textModelConfigured
            && blocks.contains(where: needsTranslation)
    }

    private var modelCacheKey: String {
        blocks.map(\.id.uuidString).joined(separator: ",")
            + "|\(target.minimalIdentifier)|\(sourceOverride?.minimalIdentifier ?? "auto")"
    }

    /// Runs through `IntelligenceCoordinator` (via `LLMTranslator.live`), so routing, the free-model
    /// fallback and local-only mode apply exactly as they do for Chat. A failure is logged and leaves
    /// pass 1 on screen: no error card.
    private func startModelPass() {
        guard modelTask == nil else { return }
        let key = modelCacheKey
        let gen = generation
        let input = blocks
        let targetName = Locale(identifier: "en").localizedString(forIdentifier: target.minimalIdentifier)
            ?? target.minimalIdentifier
        let limit = LLMTranslation.chunkLimit(contextTokens: IntelligenceCoordinator.shared.effectiveContextTokens)
        modelPass = .running
        modelTask = Task {
            var failure: String?
            do {
                try await LLMTranslator.live.translate(input, targetName: targetName, chunkLimit: limit) { id, text in
                    await MainActor.run {
                        guard generation == gen else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { llm[id] = text }
                    }
                }
            } catch {
                failure = error.localizedDescription
                if !(error is CancellationError) {
                    Log.intelligence.error("Translate model pass failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard generation == gen, !Task.isCancelled else { return }
            modelTask = nil
            if llm.isEmpty {
                if failure == nil { Log.intelligence.notice("Translate model pass returned no usable blocks") }
                modelPass = .failed(reason: failure ?? "The model returned no usable translation.")
            } else {
                let model = IntelligenceCoordinator.shared.lastProviderName
                modelCache[key] = (model, llm)
                modelPass = .improved(model: model)
            }
        }
    }

    // MARK: - Helpers

    private func samplePlateColors() {
        guard let image, let sampler = PlateBackgroundSampler(image: image) else { return }
        var styles: [UUID: PlateStyle] = [:]
        for block in blocks {
            guard let bg = sampler.background(around: block.frame) else { continue }
            styles[block.id] = PlateStyle(fill: Color(red: bg.r, green: bg.g, blue: bg.b),
                                          text: bg.luminance > 0.55 ? .black : .white)
        }
        plateStyles = styles
    }

    /// Map a Vision normalized box (origin bottom-left, within the crop) to view points.
    private func viewRect(for box: CGRect) -> CGRect {
        let x = selectionRect.minX + box.minX * selectionRect.width
        let y = selectionRect.minY + (1 - box.maxY) * selectionRect.height
        let w = box.width * selectionRect.width
        let h = box.height * selectionRect.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func displayName(_ lang: Locale.Language) -> String {
        let id = lang.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: id)
            ?? lang.languageCode?.identifier
            ?? id
    }
}

/// A horizontal shimmer used for skeleton placeholders while a block is still translating.
private struct Shimmer: View {
    var tint: Color = .white.opacity(0.25)
    @State private var phase: CGFloat = -0.6

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, tint, .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width)
            .offset(x: phase * geo.size.width)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
        }
    }
}
