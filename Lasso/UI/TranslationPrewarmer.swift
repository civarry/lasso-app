import SwiftUI
import Translation

/// Invisible helper shown during the action-bar phase. As soon as OCR finds foreign text it either:
///   • **speculatively translates** the selection's largest foreign-language group of blocks in the
///     background and caches it on the coordinator by block id, so tapping Translate is instant, or
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
    @State private var work: [TextBlock] = []

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task { await prepare() }
            .translationTask(config) { @Sendable session in
                let (currentMode, currentTarget, blocks) =
                    await MainActor.run { (mode, target, work) }
                switch currentMode {
                case .prewarm:
                    try? await session.prepareTranslation()
                case .translate:
                    await speculativelyTranslate(with: session, target: currentTarget,
                                                 blocks: blocks)
                }
            }
    }

    private func prepare() async {
        guard !lines.isEmpty else { return }

        let systemTarget = Locale.Language(
            identifier: Locale.current.language.languageCode?.identifier ?? "en")

        // The largest group of blocks not already in the target (nil when nothing is foreign). Only
        // that group is pre-translated; the overlay translates any other language's blocks itself.
        let blocks = TextBlocks.group(lines)
        guard let first = TranslationPlan.groups(blocks, target: systemTarget, override: nil).first
        else { return }

        // Only act when the pair is installed — never prompt a download speculatively.
        let status = await LanguageAvailability().status(from: first.source, to: systemTarget)
        guard status == .installed else { return }

        target = systemTarget
        work = first.blocks

        // Decide between full speculative translation and just warming the model. Pass 1 only: the
        // LLM pass never runs from here, since the user hasn't chosen Translate yet.
        let enabled = UserDefaults.standard.bool(forKey: "translation.pretranslate")
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let withinSizeCap = lines.count <= 40
        mode = (enabled && !lowPower && withinSizeCap) ? .translate : .prewarm

        config = TranslationSession.Configuration(source: first.source, target: systemTarget)
    }

    nonisolated private func speculativelyTranslate(with session: TranslationSession,
                                                    target: Locale.Language,
                                                    blocks: [TextBlock]) async {
        let started = Date()
        let mapped = Pass1Results()
        do {
            try await BlockTranslationPass.run(blocks, session: session) { ids, text in
                if Task.isCancelled { return }   // user opened the overlay or re-selected
                await mapped.set(ids, text)
            }
        } catch {
            return
        }
        if Task.isCancelled { return }
        let duration = Date().timeIntervalSince(started)
        let cached = await mapped.values
        await MainActor.run {
            CaptureCoordinator.shared.pretranslated = cached
            CaptureCoordinator.shared.pretranslatedTarget = target
            CaptureCoordinator.shared.pretranslatedDuration = duration
        }
    }
}

private actor Pass1Results {
    var values: [UUID: String] = [:]
    func set(_ ids: [UUID], _ text: String) { for id in ids { values[id] = text } }
}

/// Pass 1: Apple's Translation framework over blocks, all from the session's one source language.
/// Identical block texts are translated once. `apply` gets every block id sharing a result.
enum BlockTranslationPass {
    static func run(_ blocks: [TextBlock], session: TranslationSession,
                    apply: @Sendable ([UUID], String) async -> Void) async throws {
        var groups: [String: [UUID]] = [:]
        var order: [String] = []
        for block in blocks {
            if groups[block.text] == nil { order.append(block.text) }
            groups[block.text, default: []].append(block.id)
        }
        var idsForRequest: [String: [UUID]] = [:]
        var requests: [TranslationSession.Request] = []
        for text in order {
            let cid = UUID().uuidString
            idsForRequest[cid] = groups[text]
            requests.append(.init(sourceText: text, clientIdentifier: cid))
        }
        guard !requests.isEmpty else { return }
        for try await response in session.translate(batch: requests) {
            guard let cid = response.clientIdentifier, let ids = idsForRequest[cid] else { continue }
            await apply(ids, response.targetText)
        }
    }
}
