import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// Regression: the capture side (translate detection, result cards closing). Each test is a bug a QA pass
/// found; it fails without its fix.
@MainActor
@Suite(.serialized)
struct CaptureRegressionTests {

    // MARK: Translate (single-pane card: Identify text mode, and Translate with no line geometry)

    @Test func singlePaneTranslateDetectsALatinSourceForALatinTarget() {
        let spanish = "Hola, ¿cómo estás? Me gustaría reservar una mesa para dos personas esta noche."
        let detected = LanguageDetect.dominantNonTargetLanguage(in: spanish, targetBase: "en")
        // nil makes TranslationResultView say "This looks like it's already in English".
        #expect(detected != nil, "Spanish text with target English was treated as already English")
    }

    // MARK: Translate (inline overlay)

    @Test func traditionalChineseIsTranslatedIntoSimplified() {
        let line = OCRLine(string: "歡迎使用繁體中文", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1))
        let block = TextBlock(id: line.id, lineIDs: [line.id], text: line.string, frame: line.boundingBox,
                              language: Locale.Language(identifier: "zh-Hant"))
        let needs = TranslationPlan.needsTranslation(block, target: Locale.Language(identifier: "zh-Hans"),
                                                     override: nil)
        #expect(needs, "zh-Hant → zh-Hans (both offered in the target menu) is skipped as 'already in target'")
    }

    // MARK: Result card lifecycle

    @Test func closingAResultCardStopsItsStream() async throws {
        // Counts what the card actually reads (an unbuffered pull), so "it started" means the card read.
        final class Flag: @unchecked Sendable { var terminated = false; var pulled = 0 }
        let flag = Flag()
        struct Pulls: AsyncSequence {
            typealias Element = String
            let flag: Flag
            struct Iterator: AsyncIteratorProtocol {
                let flag: Flag
                var n = 0
                mutating func next() async throws -> String? {
                    guard !Task.isCancelled, n < 100 else { flag.terminated = true; return nil }
                    n += 1
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { flag.terminated = true; return nil }
                    flag.pulled += 1
                    return "x"
                }
            }
            func makeAsyncIterator() -> Iterator { Iterator(flag: flag) }
        }
        let stream = AsyncThrowingStream<String, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task {
                do { for try await piece in Pulls(flag: flag) { continuation.yield(piece) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel(); flag.terminated = true }
        }
        FloatingPanelController.shared.present(
            AnyView(FloatingResultView(title: "Summarize", result: .stream(stream))),
            anchor: CGRect(x: 200, y: 400, width: 100, height: 50))
        for _ in 0..<40 where flag.pulled == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        let before = flag.pulled
        #expect(before > 0, "the card never started reading its stream")
        FloatingPanelController.shared.close()   // ✕ / Esc
        for _ in 0..<80 where !flag.terminated { try await Task.sleep(for: .milliseconds(50)) }
        #expect(flag.terminated,
                "card closed, but its stream is still running (\(flag.pulled - before) more pieces after close)")
    }

    /// Control for the test above: cancelling the consumer does terminate this kind of stream, so the
    /// failure there is the card's consumer outliving the card, not the probe.
    @Test func controlCancellingTheConsumerTerminatesTheStream() async throws {
        final class Flag: @unchecked Sendable { var terminated = false }
        let flag = Flag()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.onTermination = { _ in flag.terminated = true }
            Task { for _ in 0..<100 { if flag.terminated { break }; continuation.yield("x")
                                        try? await Task.sleep(for: .milliseconds(50)) }; continuation.finish() }
        }
        let consumer = Task { for try await _ in stream {} }
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(flag.terminated)
    }

    /// The mechanism behind it, for every card (IdentifyView's `.task { runPipeline() }` and
    /// `.onDisappear { synthTask?.cancel() }`, AskAIView, TextActionsView): closing a card only
    /// orders its window out, so neither `.onDisappear` nor `.task` cancellation happens.
    @Test func closingACardEndsItsViewLifecycle() async throws {
        final class Probe: @unchecked Sendable { var started = false; var disappeared = false; var taskCancelled = false }
        let probe = Probe()
        struct ProbeView: View {
            let probe: Probe
            var body: some View {
                Text("probe").frame(width: 320, height: 120)
                    .task { probe.started = true
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                        probe.taskCancelled = true
                    }
                    .onDisappear { probe.disappeared = true }
            }
        }
        FloatingPanelController.shared.present(AnyView(ProbeView(probe: probe)),
                                               anchor: CGRect(x: 200, y: 400, width: 100, height: 50))
        try await Task.sleep(for: .milliseconds(400))
        FloatingPanelController.shared.close()
        try await Task.sleep(for: .milliseconds(800))
        #expect(probe.started, "probe never rendered")
        #expect(probe.disappeared, "onDisappear never ran after close()")
        #expect(probe.taskCancelled, ".task was never cancelled after close()")
    }
}
