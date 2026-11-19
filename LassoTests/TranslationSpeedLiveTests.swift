import Testing
import Foundation
import Translation
@testable import Lasso

/// Pass 1 against Apple's real translator: cancelling a run must free it quickly. Apple can't take
/// back a batch it was handed, so a pre-translation cancelled by tapping Translate used to hold the
/// overlay's first line back for seconds. Opt-in (real engine, needs the Spanish → English pair):
///
///     TEST_RUNNER_LASSO_LIVE=1 xcodebuild test -scheme Lasso -only-testing:LassoTests/TranslationSpeedLiveTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_LIVE"] == "1"))
struct TranslationSpeedLiveTests {
    private let es = Locale.Language(identifier: "es")
    private let en = Locale.Language(identifier: "en")

    private func blocks(_ tag: String) -> [TextBlock] {
        let base = ["Hoy hace muy buen tiempo.", "¿Dónde está la estación?",
                    "La comida de este menú es deliciosa.", "El horario es de diez a ocho."]
        return (0..<8).flatMap { i in base.map { "\($0) \(tag)\(i)" } }.map {
            TextBlock(id: UUID(), lineIDs: [], text: $0, frame: .zero, language: es)
        }
    }

    @Test func cancelledRunDoesNotHoldUpTheNextOne() async throws {
        guard await LanguageAvailability().status(from: es, to: en) == .installed else { return }
        _ = try await TranslationSession(installedSource: es, target: en).translate("Hola")

        // A 32-block pre-translation, cancelled a second in (the user tapped Translate).
        let abandoned = blocks("a")
        let job = Task {
            try await BlockTranslationPass.run(abandoned, session: TranslationSession(installedSource: es, target: en)) { _, _ in }
        }
        try await Task.sleep(for: .seconds(1))
        job.cancel()

        // The overlay's own run: its first line should not wait behind the abandoned work.
        let started = ContinuousClock.now
        let first = FirstLine()
        let next = blocks("b")
        try await BlockTranslationPass.run(Array(next.prefix(3)), session: TranslationSession(installedSource: es, target: en)) { _, _ in
            await first.mark()
        }
        let wait = try #require(await first.at) - started
        print("[live] first line after cancel: \(wait)")
        // One batch of 32 waited ~6 s here on an M4 Pro; groups of three, ~0.5 s.
        #expect(wait < .seconds(2))
    }
}

private actor FirstLine {
    var at: ContinuousClock.Instant?
    func mark() { if at == nil { at = .now } }
}
