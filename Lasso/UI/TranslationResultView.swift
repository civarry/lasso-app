import SwiftUI
import Translation

/// On-device translation of the selected text via the Translation framework. A live
/// `TranslationSession` is vended by `.translationTask` (the only supported entry point). Carries the
/// same language bar as the inline overlay translator — an auto-detecting **source** picker, a
/// **swap** button, and a **target** picker (Spec §9) — so the user controls both directions.
struct TranslationResultView: View {
    let source: String

    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: String = ""
    @State private var failure: String?
    @State private var target: Locale.Language =
        Locale.Language(identifier: Locale.current.language.languageCode?.identifier ?? "en")
    @State private var sourceOverride: Locale.Language?
    @State private var detectedSource: Locale.Language?

    private let languageChoices: [Locale.Language] = [
        "en", "zh-Hant", "zh-Hans", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "th",
    ].map(Locale.Language.init(identifier:))

    private var activeSource: Locale.Language? { sourceOverride ?? detectedSource }
    /// The text is already in the target language (nothing to translate) when auto-detect finds no
    /// non-target language and the user hasn't overridden the source.
    private var alreadyInTarget: Bool { sourceOverride == nil && detectedSource == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            languageBar

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if alreadyInTarget {
                Label("This looks like it's already in \(displayName(target)). Pick a different "
                      + "target language above.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if translated.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Translating…") }
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(translated)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 200)
                .padding(12)
                .glassWell()
                Button("Copy translation") { Pasteboard.copy(translated) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { rebuild() }
        .onChange(of: target) { _, _ in rebuild() }
        .onChange(of: sourceOverride) { _, _ in rebuild() }
        // `@Sendable` makes the closure nonisolated so the (non-Sendable) `session` is never "sent"
        // off the main actor when calling the nonisolated `translate`. State writes hop back explicitly.
        .translationTask(configuration) { @Sendable session in
            do {
                let text = try await session.translate(source).targetText
                await MainActor.run { translated = text }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { failure = "Translation unavailable: \(message)" }
            }
        }
    }

    /// One capsule: source name · accent-glass swap · target name — like the iOS Translate bar. Names
    /// are plain text (tap opens a picker, but no chevron/box so it doesn't read as a form dropdown).
    private var languageBar: some View {
        HStack(spacing: 10) {
            languageLabel(title: sourceLabel, selection: { sourceOverride = $0 }, includeAuto: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let current = activeSource {          // swap source ↔ target
                    sourceOverride = target
                    target = current
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
            .disabled(activeSource == nil)
            .help("Swap languages")

            languageLabel(title: displayName(target), selection: { if let l = $0 { target = l } },
                          includeAuto: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    /// A language name that opens the picker on tap but is styled as plain text — no chevron, no box,
    /// no dropdown affordance. Both names share the same size/weight (no hierarchy).
    private func languageLabel(title: String,
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
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var sourceLabel: String {
        if sourceOverride == nil {
            return detectedSource.map(displayName) ?? "Auto"
        }
        return displayName(sourceOverride!)
    }

    /// Re-detect the source relative to the current target, then (re)build the session — skipping the
    /// request entirely when the text is already in the target language, so we never fire a useless
    /// same-language translate that the framework rejects with "Unable to Translate".
    private func rebuild() {
        translated = ""
        failure = nil
        let targetBase = LanguageDetect.baseCode(target.languageCode?.identifier ?? "en")
        detectedSource = LanguageDetect.dominantNonTargetLanguage(in: source, targetBase: targetBase)
        guard let src = activeSource else { configuration = nil; return }
        configuration = TranslationSession.Configuration(source: src, target: target)
    }

    private func displayName(_ lang: Locale.Language) -> String {
        let id = lang.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: id)
            ?? lang.languageCode?.identifier
            ?? id
    }
}
