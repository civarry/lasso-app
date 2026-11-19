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
        // The first group whose pair is installed: never prompt a download speculatively, and skip
        // languages Apple can't translate at all (Filipino), which only the model pass handles.
        let blocks = TextBlocks.group(lines)
        var chosen: (source: Locale.Language, blocks: [TextBlock])?
        for group in TranslationPlan.groups(blocks, target: systemTarget, override: nil) {
            if await LanguageAvailability().status(from: group.source, to: systemTarget) == .installed {
                chosen = group
                break
            }
        }
        guard let first = chosen else { return }

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

    /// Each block lands in the coordinator's cache the moment it's translated, not when the whole
    /// selection is done: tapping Translate cancels this view, and whatever it finished by then is
    /// kept instead of being translated again.
    nonisolated private func speculativelyTranslate(with session: TranslationSession,
                                                    target: Locale.Language,
                                                    blocks: [TextBlock]) async {
        let started = Date()
        // Back from the overlay to the bar, this view runs again: keep what's cached for this target.
        let todo = await MainActor.run { () -> [TextBlock] in
            let shared = CaptureCoordinator.shared
            if shared.pretranslatedTarget != target {
                shared.pretranslated = [:]
                shared.pretranslatedDuration = nil
                shared.pretranslatedTarget = target
            }
            return blocks.filter { shared.pretranslated[$0.id] == nil }
        }
        guard !todo.isEmpty else { return }
        do {
            try await BlockTranslationPass.run(todo, session: session) { ids, text in
                // Still written after a cancel: it's a correct translation for this target, and the
                // overlay picks it up.
                await MainActor.run {
                    let shared = CaptureCoordinator.shared
                    guard shared.pretranslatedTarget == target else { return }
                    for id in ids { shared.pretranslated[id] = text }
                }
            }
        } catch {
            return
        }
        if Task.isCancelled { return }
        let duration = Date().timeIntervalSince(started)
        await MainActor.run { CaptureCoordinator.shared.pretranslatedDuration = duration }
    }
}

/// Pass 1: Apple's Translation framework over blocks, all from the session's one source language.
/// Identical block texts are translated once. `apply` gets every block id sharing a result.
///
/// Work goes to Apple a few blocks at a time. Its translator does one request after another and a
/// batch handed over can't be taken back: cancelling a 32-block batch left the next request waiting
/// 6.1 s for its first line on an M4 Pro, against 0.5 s when the cancelled work went in groups of
/// three (0.27 s with nothing ahead). So a cancel (Translate tapped mid pre-translation, a language
/// changed) frees the translator within one small group. Throughput cost: about 5%.
enum BlockTranslationPass {
    struct Request: Equatable, Sendable {
        let text: String
        let ids: [UUID]
    }

    /// Blocks handed to Apple at once.
    static let groupSize = 3

    /// One request per distinct text, in first-seen order, with every block id that shares it,
    /// split into groups of `size`.
    static func plan(_ blocks: [TextBlock], size: Int = groupSize) -> [[Request]] {
        var ids: [String: [UUID]] = [:]
        var order: [String] = []
        for block in blocks {
            if ids[block.text] == nil { order.append(block.text) }
            ids[block.text, default: []].append(block.id)
        }
        let requests = order.map { Request(text: $0, ids: ids[$0] ?? []) }
        let step = max(size, 1)
        return stride(from: 0, to: requests.count, by: step).map {
            Array(requests[$0..<min($0 + step, requests.count)])
        }
    }

    static func run(_ blocks: [TextBlock], session: TranslationSession,
                    apply: @Sendable ([UUID], String) async -> Void) async throws {
        for group in plan(blocks) {
            if Task.isCancelled { return }
            var idsForRequest: [String: [UUID]] = [:]
            let requests = group.map { request -> TranslationSession.Request in
                let cid = UUID().uuidString
                idsForRequest[cid] = request.ids
                return .init(sourceText: request.text, clientIdentifier: cid)
            }
            for try await response in session.translate(batch: requests) {
                guard let cid = response.clientIdentifier, let ids = idsForRequest[cid] else { continue }
                await apply(ids, response.targetText)
            }
        }
    }
}
