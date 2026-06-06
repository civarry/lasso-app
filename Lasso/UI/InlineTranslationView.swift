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
            if !showOriginal {
                ForEach(lines) { line in
                    if let text = translations[line.id], !text.isEmpty {
                        let r = viewRect(for: line.boundingBox)
                        Text(text)
                            .font(.system(size: max(9, r.height * 0.66), weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.3)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(width: max(r.width, 10), height: r.height, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.82)))
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }

            languageBar.position(barPoint(in: geo.size))
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .task {
            detectedSource = detectSourceLanguage()
            rebuildConfig()
        }
        .onChange(of: target) { _, _ in rebuildConfig() }
        .onChange(of: sourceOverride) { _, _ in rebuildConfig() }
        .translationTask(config) { @Sendable session in
            // Translate every line in ONE batched call (per-line awaits are far slower).
            let requests = lines.map {
                TranslationSession.Request(sourceText: $0.string, clientIdentifier: $0.id.uuidString)
            }
            let started = Date()
            guard let responses = try? await session.translations(from: requests) else { return }
            let seconds = Date().timeIntervalSince(started)
            var mapped: [UUID: String] = [:]
            for response in responses {
                if let idString = response.clientIdentifier, let id = UUID(uuidString: idString) {
                    mapped[id] = response.targetText
                }
            }
            await MainActor.run {
                translations = mapped
                lastDuration = seconds
            }
        }
        }
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
        return CGPoint(x: x, y: y)
    }

    private var languageBar: some View {
        HStack(spacing: 10) {
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

            if let lastDuration {
                Divider().frame(height: 18)
                Label(String(format: "%d lines · %.2fs", translations.count, lastDuration),
                      systemImage: "clock")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Divider().frame(height: 18)

            Button { showOriginal.toggle() } label: {
                Image(systemName: showOriginal ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .help(showOriginal ? "Show translation" : "Show original")

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
