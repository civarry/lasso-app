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
        // Counts what the card actually reads: an unfolding stream makes a piece only when the card asks
        // for one, so "it started" means the card read (a producer task pulled on its own, which passed
        // on a CI machine where the card never read at all). The card's cancel ends the pending sleep.
        final class Flag: @unchecked Sendable { var terminated = false; var pulled = 0 }
        let flag = Flag()
        let stream = AsyncThrowingStream<String, Error>(unfolding: {
            guard flag.pulled < 100 else { return nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { flag.terminated = true; return nil }
            if Task.isCancelled { flag.terminated = true; return nil }
            flag.pulled += 1
            return "x"
        })
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

/// Regression: the capture session (selection, pre-pass, actions, Esc), driven over a synthetic picture
/// through the DEBUG `startForTesting` hook, no real screen grab. Each test is a bug a QA pass found.
@MainActor
@Suite(.serialized)
struct CaptureSessionRegressionTests {
    static func shot() throws -> DisplayShot {
        let ctx = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return DisplayShot(id: 99_999, image: try #require(ctx.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
    }

    struct FakeAction: CaptureAction {
        var id = "qa.fake"
        var title = "Fake"
        var systemImage = "star"
        var relevancePriority = 99
        var delay: Duration = .zero
        var outcome: ActionResult = .text("done")
        func isRelevant(to ctx: CaptureContext) -> Bool { true }
        func disabledReason(for ctx: CaptureContext, visionAvailable: Bool) -> String? { nil }
        func perform(_ ctx: CaptureContext) async throws -> ActionResult {
            try await Task.sleep(for: delay)
            return outcome
        }
    }

    func session(_ body: (CaptureCoordinator) async throws -> Void) async throws {
        let capture = CaptureCoordinator.shared
        capture.startForTesting([try Self.shot()])
        defer { capture.prePassDelayForTesting = nil; capture.cancel(); FloatingPanelController.shared.close() }
        try await body(capture)
    }

    /// An older selection's slow pre-pass finished last and replaced the newer selection's context
    /// (Copy text copied the first area).
    @Test func anOlderPrePassNeverOverwritesANewerSelection() async throws {
        try await session { capture in
            let first = CGRect(x: 10, y: 10, width: 300, height: 200)
            let second = CGRect(x: 400, y: 300, width: 100, height: 80)
            capture.prePassDelayForTesting = { $0 == first ? .milliseconds(600) : nil }
            capture.commitSelection(rectInPoints: first, displayID: 99_999)
            capture.commitSelection(rectInPoints: second, displayID: 99_999)
            try await Task.sleep(for: .milliseconds(1_200))
            #expect(capture.context?.selectionRect == second, "context is for \(String(describing: capture.context?.selectionRect))")
        }
    }

    /// After Esc, a pre-pass still running put its picture back on the torn-down session.
    @Test func aPrePassAfterEscLeavesNothingBehind() async throws {
        let capture = CaptureCoordinator.shared
        capture.startForTesting([try Self.shot()])
        capture.prePassDelayForTesting = { _ in .milliseconds(300) }
        defer { capture.prePassDelayForTesting = nil }
        capture.commitSelection(rectInPoints: CGRect(x: 10, y: 10, width: 200, height: 100), displayID: 99_999)
        capture.cancel()
        try await Task.sleep(for: .milliseconds(700))
        #expect(capture.context == nil, "a cancelled session's pre-pass wrote its context back")
    }

    /// Esc while an action ran still showed its card afterwards.
    @Test func escWhileAnActionRunsShowsNoCard() async throws {
        try await session { capture in
            capture.commitSelection(rectInPoints: CGRect(x: 10, y: 10, width: 200, height: 100), displayID: 99_999)
            capture.run(FakeAction(delay: .milliseconds(300)))
            capture.cancel()
            try await Task.sleep(for: .milliseconds(700))
            #expect(!NSApp.windows.contains { $0 is FloatingPanel && $0.isVisible && $0 !== ChatPanelController.shared.panel },
                    "a card appeared for a dismissed capture")
        }
    }

    /// A new selection kept showing the old selection's inline translation.
    @Test func aNewSelectionLeavesInlineTranslate() async throws {
        try await session { capture in
            capture.commitSelection(rectInPoints: CGRect(x: 10, y: 10, width: 200, height: 100), displayID: 99_999)
            capture.run(FakeAction(outcome: .inlineTranslate))
            for _ in 0..<20 where !capture.translating { try await Task.sleep(for: .milliseconds(25)) }
            #expect(capture.translating, "precondition: translating")
            capture.commitSelection(rectInPoints: CGRect(x: 400, y: 300, width: 100, height: 80), displayID: 99_999)
            #expect(!capture.translating, "the old translation stays over the new selection")
        }
    }

    /// The Lens card's button, drawn before local-only mode was turned on, still uploaded.
    @Test func lensNeverOpensInLocalOnlyMode() throws {
        let defaults = UserDefaults.standard
        let was = (defaults.object(forKey: "privacy.localOnly"), defaults.object(forKey: LensSearchAction.enabledKey))
        defer {
            defaults.set(was.0, forKey: "privacy.localOnly"); defaults.set(was.1, forKey: LensSearchAction.enabledKey)
            LensPanelController.shared.close()
        }
        defaults.set(true, forKey: LensSearchAction.enabledKey)
        defaults.set(true, forKey: "privacy.localOnly")
        let image = try Self.shot().image
        let before = NSApp.windows.filter(\.isVisible).count
        LensPanelController.shared.present(image: image, anchor: nil)
        #expect(NSApp.windows.filter(\.isVisible).count == before, "Lens opened (and would upload) in local-only mode")
    }
}
