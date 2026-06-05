import SwiftUI
import Translation

/// On-device translation of the selected text via the Translation framework. A live
/// `TranslationSession` is vended by `.translationTask` (the only supported entry point); source
/// language is auto-detected, target defaults to the system locale (Spec §9).
struct TranslationResultView: View {
    let source: String

    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: String = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
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
                .frame(maxHeight: 200)
                Button("Copy translation") { Pasteboard.copy(translated) }
                    .buttonStyle(.link)
            }
        }
        .frame(width: 400)
        .task { configuration = TranslationSession.Configuration() }
        // `@Sendable` makes the closure nonisolated so the (non-Sendable) `session` is never
        // "sent" off the main actor when calling the nonisolated `translate`. State writes hop
        // back to the main actor explicitly.
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
}
