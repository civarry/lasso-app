import SwiftUI
import Translation
import NaturalLanguage

/// Invisible helper shown during the action-bar phase. As soon as OCR finds foreign text it either:
///   • **speculatively translates** the selection in the background and caches the result on the
///     coordinator, so tapping Translate is instant, or
///   • **pre-warms** the model only (loads it) when full pre-translation isn't worth it.
///
/// Guards keep the speculative path cheap: only for foreign text, only when the model is already
/// installed (no download prompt), only for reasonably small selections, off in Low Power Mode, and
/// cancelled automatically when the view goes away (e.g. the user opens the translate overlay or
/// re-selects). Controlled by the "Pre-translate selections" setting.
struct TranslationPrewarmer: View {
    let lines: [OCRLine]

    private enum Mode { case prewarm, translate }

    @State private var config: TranslationSession.Configuration?
    @State private var mode: Mode = .prewarm
    @State private var target = Locale.Language(identifier: "en")

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task { await prepare() }
            .translationTask(config) { @Sendable session in
                let (currentMode, currentTarget) = await MainActor.run { (mode, target) }
                switch currentMode {
                case .prewarm:
                    try? await session.prepareTranslation()
                case .translate:
                    await speculativelyTranslate(with: session, target: currentTarget)
                }
            }
    }

    private func prepare() async {
        let text = lines.map(\.string).joined(separator: " ")
        guard !text.isEmpty else { return }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return }

        let source = Locale.Language(identifier: dominant.rawValue)
        let systemTarget = Locale.Language(
            identifier: Locale.current.language.languageCode?.identifier ?? "en")

        // Nothing to do if the text is already in the target language.
        if source.languageCode == systemTarget.languageCode { return }

        // Only act when the pair is installed — never prompt a download speculatively.
        let status = await LanguageAvailability().status(from: source, to: systemTarget)
        guard status == .installed else { return }

        target = systemTarget

        // Decide between full speculative translation and just warming the model.
        let enabled = UserDefaults.standard.bool(forKey: "translation.pretranslate")
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let withinSizeCap = lines.count <= 40
        mode = (enabled && !lowPower && withinSizeCap) ? .translate : .prewarm

        config = TranslationSession.Configuration(source: source, target: systemTarget)
    }

    nonisolated private func speculativelyTranslate(with session: TranslationSession,
                                                    target: Locale.Language) async {
        let requests = lines.map {
            TranslationSession.Request(sourceText: $0.string, clientIdentifier: $0.id.uuidString)
        }
        let started = Date()
        var mapped: [UUID: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                if Task.isCancelled { return }   // user opened the overlay or re-selected
                if let cid = response.clientIdentifier, let id = UUID(uuidString: cid) {
                    mapped[id] = response.targetText
                }
            }
        } catch {
            return
        }
        let duration = Date().timeIntervalSince(started)
        let cached = mapped
        await MainActor.run {
            CaptureCoordinator.shared.pretranslated = cached
            CaptureCoordinator.shared.pretranslatedTarget = target
            CaptureCoordinator.shared.pretranslatedDuration = duration
        }
    }
}
