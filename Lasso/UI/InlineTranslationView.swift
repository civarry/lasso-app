import SwiftUI
import Translation
import NaturalLanguage

/// Google-style "translate in place": overlays translated text directly over each OCR line within
/// the selection, with a source → target language bar at the bottom (Spec §9).
///
/// The source language is detected ONCE over the whole selection with NaturalLanguage (robust),
/// then passed explicitly to every line translation. Per-line auto-detect (`source: nil`) misfires
/// on short strings and triggers the system "choose a language" sheet, so we avoid it.
///
/// Closing is routed through `CaptureCoordinator.shared` (not a stored closure) so this view stays
/// `Sendable` — required because the `.translationTask` work runs in a `@Sendable` closure.
struct InlineTranslationView: View {
    let lines: [OCRLine]
    /// Selection rectangle in this view's point coordinates (top-left origin).
    let selectionRect: CGRect

    @State private var config: TranslationSession.Configuration?
    @State private var translations: [UUID: String] = [:]
    @State private var detectedSource: Locale.Language?
    @State private var sourceOverride: Locale.Language?
    @State private var showOriginal = false
    @State private var readingMode = false
    @State private var lastDuration: TimeInterval?
    @State private var target: Locale.Language =
        Locale.Language(identifier: Locale.current.language.languageCode?.identifier ?? "en")

    private let languageChoices: [Locale.Language] = [
        "en", "zh-Hant", "zh-Hans", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "th",
    ].map(Locale.Language.init(identifier:))

    private var activeSource: Locale.Language? { sourceOverride ?? detectedSource }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            if readingMode {
                readingPanel(in: geo.size)
            } else if !showOriginal {
                ForEach(lines) { line in
                    let r = viewRect(for: line.boundingBox)
                    if let text = translations[line.id], !text.isEmpty {
                        // Readability-first: font clamped to a readable band (never huge/tiny),
                        // wrap freely within ~the original column width, grow downward. Anchored at
                        // the line's top-left so it stays aligned with the source.
                        let fontSize = min(24, max(12, r.height * 0.7))
                        // Wrap within the original line's own width so the translation spans the
                        // same horizontal area (stays ~1–2 lines) instead of stacking into a tall
                        // narrow column that overlaps neighbouring lines.
                        let wrapWidth = max(r.width, 140)
                        Text(text)
                            .font(.system(size: fontSize, weight: .medium))
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .frame(maxWidth: wrapWidth, minHeight: r.height, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.85)))
                            .offset(x: r.minX, y: r.minY)
                    } else {
                        // Skeleton placeholder until this line's translation streams in.
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.black.opacity(0.55))
                            .frame(width: max(r.width, 10), height: r.height)
                            .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 3)))
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }

            languageBar.position(barPoint(in: geo.size))
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .task {
            detectedSource = detectSourceLanguage()
            // If the background pre-translation already finished for this target, reuse it instantly
            // and skip re-translating.
            let shared = CaptureCoordinator.shared
            if sourceOverride == nil, !shared.pretranslated.isEmpty, shared.pretranslatedTarget == target {
                translations = shared.pretranslated
                lastDuration = shared.pretranslatedDuration
            } else {
                rebuildConfig()
            }
        }
        .onChange(of: target) { _, _ in rebuildConfig() }
        .onChange(of: sourceOverride) { _, _ in rebuildConfig() }
        .translationTask(config) { @Sendable session in
            // Group identical source strings so each unique string is translated once, and skip
            // lines with no letters (pure numbers/symbols/emoji) — they need no translation.
            var groups: [String: [UUID]] = [:]
            for line in lines { groups[line.string, default: []].append(line.id) }

            var requests: [TranslationSession.Request] = []
            var idsForRequest: [String: [UUID]] = [:]
            var passthrough: [UUID: String] = [:]
            for (text, ids) in groups {
                if text.contains(where: \.isLetter) {
                    let cid = UUID().uuidString
                    idsForRequest[cid] = ids
                    requests.append(.init(sourceText: text, clientIdentifier: cid))
                } else {
                    for id in ids { passthrough[id] = text }
                }
            }
            if !passthrough.isEmpty {
                await MainActor.run { for (id, text) in passthrough { translations[id] = text } }
            }

            // Stream results so lines fill in progressively (skeletons resolve as they arrive).
            let started = Date()
            do {
                for try await response in session.translate(batch: requests) {
                    guard let cid = response.clientIdentifier, let ids = idsForRequest[cid] else { continue }
                    let text = response.targetText
                    await MainActor.run { for id in ids { translations[id] = text } }
                }
                let seconds = Date().timeIntervalSince(started)
                await MainActor.run { lastDuration = seconds }
            } catch {
                Log.app.error("Translate batch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        }
    }

    /// Clean, scrollable reading view of the full translation in order — no overlap, for dense
    /// text. Anchored to the language bar (below it, flipping above when there's no room), aligned
    /// horizontally with it, so it matches the Summarize / Ask AI result-pane pattern.
    private func readingPanel(in size: CGSize) -> some View {
        let joined = lines.compactMap { translations[$0.id] }.joined(separator: "\n")
        let panelWidth = min(540, size.width - 48)
        let panelHeight = min(size.height * 0.5, 380)
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

        return ScrollView {
            Text(joined.isEmpty ? "Translating…" : joined)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: panelWidth, height: panelHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .position(x: centerX, y: centerY)
    }

    /// Center point for the language bar: just below the selection, flipped above if there's no
    /// room, and clamped horizontally so the bar stays on screen.
    private func barPoint(in size: CGSize) -> CGPoint {
        let gap: CGFloat = 16, halfHeight: CGFloat = 24, halfWidth: CGFloat = 280, margin: CGFloat = 16
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
                title: sourceLabel,
                selection: { sourceOverride = $0 },
                includeAuto: true
            )

            Button {
                // Swap source/target.
                if let current = activeSource {
                    let newTarget = current
                    sourceOverride = target
                    target = newTarget
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Swap languages")

            languageMenu(
                title: displayName(target),
                selection: { if let l = $0 { target = l } },
                includeAuto: false
            )

            Divider().frame(height: 18)
            if let lastDuration {
                Label(String(format: "%d lines · %.2fs", translations.count, lastDuration),
                      systemImage: "clock")
                    .font(.caption).monospacedDigit().foregroundStyle(.primary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(translations.count)/\(lines.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.primary)
                }
            }

            Divider().frame(height: 18)

            Button { readingMode.toggle() } label: {
                Image(systemName: readingMode ? "rectangle.on.rectangle" : "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .help(readingMode ? "Overlay view" : "Reading view")

            if !readingMode {
                Button { showOriginal.toggle() } label: {
                    Image(systemName: showOriginal ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .help(showOriginal ? "Show translation" : "Show original")
            }

            Button { CaptureCoordinator.shared.exitTranslate() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Done")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
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

    private var sourceLabel: String {
        if sourceOverride == nil, let detectedSource {
            return "Detected · \(displayName(detectedSource))"
        }
        if let s = activeSource { return displayName(s) }
        return "Detecting…"
    }

    private func rebuildConfig() {
        translations = [:]
        lastDuration = nil
        config = TranslationSession.Configuration(source: activeSource, target: target)
    }

    /// Detect the dominant language across all OCR lines (robust for short per-line text).
    private func detectSourceLanguage() -> Locale.Language? {
        let text = lines.map(\.string).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
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

/// A horizontal shimmer used for skeleton placeholders while a line is still translating.
private struct Shimmer: View {
    @State private var phase: CGFloat = -0.6

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.25), .clear],
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
