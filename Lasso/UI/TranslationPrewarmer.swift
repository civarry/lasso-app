import SwiftUI
import Translation
import NaturalLanguage

/// Invisible helper shown during the action-bar phase: as soon as OCR finds foreign text, it
/// quietly preloads the on-device translation model for the detected language pair so that tapping
/// Translate skips the model-load cost. Only warms when the model is already **installed**, so it
/// never triggers a language-download prompt before the user asks to translate.
struct TranslationPrewarmer: View {
    let lines: [OCRLine]

    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task { await prepare() }
            .translationTask(config) { @Sendable session in
                try? await session.prepareTranslation()
            }
    }

    private func prepare() async {
        let text = lines.map(\.string).joined(separator: " ")
        guard !text.isEmpty else { return }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return }

        let source = Locale.Language(identifier: dominant.rawValue)
        let target = Locale.Language(
            identifier: Locale.current.language.languageCode?.identifier ?? "en")

        // Nothing to warm if the text is already in the target language.
        if source.languageCode == target.languageCode { return }

        // Only preload when the pair is installed — avoid prompting a download speculatively.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { return }

        config = TranslationSession.Configuration(source: source, target: target)
    }
}
