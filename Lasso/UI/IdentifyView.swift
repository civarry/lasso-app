import SwiftUI
import AppKit

/// The Identify pipeline in a floating card. OCR-first: if the selection has strong text we skip
/// the vision model and use the text. Otherwise we run the vision model, then any enabled Identify
/// *sources* (a pluggable registry — web search, reverse-image, etc.): visual sources run first and
/// can refine the search query with a best-guess identity, then textual sources run. Everything is
/// fused and synthesized with the user's chosen provider. Each source is fault-isolated, so one
/// being off/misconfigured/broken can never break Identify.
struct IdentifyView: View {
    let image: CGImage
    let ocrText: String?
    let intelligence: IntelligenceCoordinator

    @AppStorage("ui.resultTextScale") private var textScale = 1.0

    private enum Stage { case running, done, failed, skipped
        var settled: Bool { self != .running }
    }

    @State private var vision: Stage = .running
    @State private var visionText = ""
    @State private var visionQuery = ""
    @State private var sources: Stage = .running
    @State private var query = ""
    @State private var bestGuess: String?
    @State private var entities: [String] = []
    @State private var ddgAbstract: String?
    @State private var rawHits: [WebSourcesProvider.Hit] = []    // combined, pre-ranking
    @State private var webHits: [WebSourcesProvider.Hit] = []    // ranked (display + synthesis)
    @State private var activeSources: [IdentifySource] = []
    @State private var searching = false                        // true only while sources actually run
    @State private var sourceError: String?                     // a configured source that failed

    @State private var summary = ""
    @State private var intent: IdentifyIntent = .unknown
    @State private var pipelineStart = Date()
    @State private var showVisual = false
    @State private var cacheKey = ""
    @State private var synthStarted = false
    @State private var synthesizing = false
    @State private var synthError: String?
    @State private var visionError: String?
    @State private var synthTask: Task<Void, Never>?

    private var busy: Bool {
        !(vision.settled && sources.settled) || synthesizing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusLine

            if !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        MarkdownView(text: displaySummary, fontSize: resultTextBaseSize * textScale)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    if let confidence { confidenceChip(confidence) }
                }
            } else if let synthError {
                Label(synthError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            if !visionText.isEmpty {
                // Manual disclosure — DisclosureGroup inside the auto-sizing floating panel recurses
                // its layout into a stack overflow when toggled.
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        showVisual.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showVisual ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Visual analysis").font(.subheadline)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showVisual {
                        Text(visionText)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !webHits.isEmpty {
                Divider().opacity(0.5)
                ScrollView {
                    sourceSection("Related") {
                        ForEach(webHits.prefix(8)) { webHitRow($0) }
                    }
                }
                .frame(maxHeight: 300)
            }

            if let sourceError {
                Label(sourceError, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let note = sourceFootnote {
                Label(note, systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .task { await runPipeline() }
        .onDisappear { synthTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Identify", systemImage: "sparkle.magnifyingglass").font(.headline)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            if !summary.isEmpty {
                Button { Pasteboard.copy(summary) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle()).help("Copy summary")
            }
            Button { FloatingPanelController.shared.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Close")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !(vision.settled && sources.settled) {
            let parts = [vision == .running ? "Looking at image" : nil,
                         searching ? "Searching the web" : nil]
                .compactMap { $0 }
            Text(parts.joined(separator: " · ") + "…").font(.caption).foregroundStyle(.secondary)
        } else if synthesizing && summary.isEmpty {
            Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Web search / Reverse image used — leaves your Mac" built from whatever sources actually ran.
    private var sourceFootnote: String? {
        let offDevice = activeSources.filter { $0.leavesDevice }
        guard !offDevice.isEmpty else { return nil }
        return "\(offDevice.map(\.title).joined(separator: " · ")) — leaves your Mac."
    }

    private func confidenceChip(_ c: (level: String, color: Color)) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c.color).frame(width: 7, height: 7)
            Text("\(c.level) confidence")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sourceSection(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2).padding(.bottom, 2)
            content()
        }
    }

    @ViewBuilder
    private func webHitRow(_ h: WebSourcesProvider.Hit) -> some View {
        let host = h.url?.host?.replacingOccurrences(of: "www.", with: "")
        let isReddit = h.source.hasPrefix("r/")
        SourceRow(domain: isReddit ? "reddit.com" : (host ?? ""),
                  title: h.title,
                  subtitle: isReddit ? h.source : (host ?? h.source),
                  url: h.url, score: h.score)
    }

    // MARK: - Pipeline

    /// Everything that changes what an Identify produces — engine, models, base URLs, and the set of
    /// active sources. Folded into the cache key so switching any of them invalidates a stale result.
    private var configSignature: String {
        [
            intelligence.preferred.rawValue,
            intelligence.ollamaModel, intelligence.visionModel,
            intelligence.openAIBaseURL, intelligence.openAIModel,
            intelligence.anthropicBaseURL, intelligence.anthropicModel,
            activeSources.map(\.id).sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    private func runPipeline() async {
        pipelineStart = Date()
        activeSources = IdentifySources.active()
        // Hash-cache keyed by the crop *and* the active model/source config, so changing the engine,
        // model, or connectors produces a fresh result instead of replaying a stale cached one.
        let key = IdentifyCache.hash(image, signature: configSignature)
        if let cached = IdentifyCache.get(key) {
            applyCached(cached)
            Log.intelligence.notice("⏱ Identify cache hit: \(Self.ms(pipelineStart), privacy: .public)")
            return
        }
        cacheKey = key

        // Text-heavy captures (code/article) don't benefit from reverse-image or web — decide routing
        // from the cheap OCR signal, so the visual work can start in parallel with the vision model.
        let textHeavy = hasStrongText
        let visualSources = textHeavy ? [] : activeSources.filter { $0.kind == .visual }
        let textSources = textHeavy ? [] : activeSources.filter { $0.kind == .textual }

        var merged = Evidence()

        // Vision and reverse-image are independent (reverse-image uses the picture, not the query),
        // so run them concurrently — their model/network waits overlap instead of stacking.
        let tVision = Date()
        if visualSources.isEmpty {
            await runVision()
            Log.intelligence.notice("⏱ vision (\(vision == .skipped ? "skipped" : "ran", privacy: .public)): \(Self.ms(tVision), privacy: .public)")
        } else {
            searching = true
            async let visionRun: Void = runVision()
            async let visualEvidence = gather(visualSources)
            await visionRun
            Log.intelligence.notice("⏱ vision (ran): \(Self.ms(tVision), privacy: .public)")
            merged.merge(await visualEvidence)
        }

        query = buildQuery()
        // A reverse-image best-guess is a far better search term than the vision model's guess.
        if let guess = merged.bestGuess, !guess.isEmpty { query = guess }

        // Intent (sharpens the synthesis prompt; routing was already decided from the OCR signal).
        intent = IntentDetector.detect(visionText: visionText, ocrText: ocrText, hasStrongText: hasStrongText)
        Log.intelligence.notice("⏱ intent \(intent.rawValue, privacy: .public) → sources: [\((visualSources + textSources).map(\.id).joined(separator: ", "), privacy: .public)]")

        // Text sources need the (now sharpened) query, so they run after vision/reverse-image.
        if !textSources.isEmpty {
            searching = true
            let tText = Date()
            merged.merge(await gather(textSources))
            Log.intelligence.notice("⏱ text sources: \(Self.ms(tText), privacy: .public)")
        }

        finalize(merged)
        sources = (visualSources.isEmpty && textSources.isEmpty) ? .skipped : .done
        searching = false
        maybeSynthesize()
    }

    /// Elapsed-since helper for the ⏱ pipeline timing logs.
    private static func ms(_ start: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(start) * 1000)
    }

    /// Run a set of sources, merging their evidence. Best-effort: each `gather` returns empty on
    /// failure (never throws), so one source can't break the pipeline.
    private func gather(_ sources: [IdentifySource]) async -> Evidence {
        var merged = Evidence()
        for source in sources {
            let t = Date()
            merged.merge(await source.gather(image: image, query: query, ocrText: ocrText))
            Log.intelligence.notice("⏱   \(source.id, privacy: .public): \(Self.ms(t), privacy: .public)")
        }
        return merged
    }

    private func finalize(_ merged: Evidence) {
        bestGuess = merged.bestGuess
        entities = merged.entities
        ddgAbstract = merged.abstract
        sourceError = merged.error
        rawHits = merged.hits.filter { hit in
            guard let host = hit.url?.host else { return true }
            return !DomainNoise.isNoise(host)
        }
    }

    /// Order the related hits by word overlap with the identity (best-guess / query) — keep the most
    /// relevant for display. No model: a few lines of term matching, so Identify needs only the
    /// vision model (which then stays warm). The synthesis step does the deeper reasoning.
    private func rankHits() {
        let combined = rawHits
        guard !combined.isEmpty else { return }
        let reference = bestGuess ?? (!visionQuery.isEmpty ? visionQuery
            : (!visionText.isEmpty ? visionText : (ocrText ?? "")))
        let terms = Self.keywords(reference)
        guard !terms.isEmpty else { webHits = Array(combined.prefix(6)); return }

        var scored = combined
        for index in scored.indices {
            scored[index].score = Self.overlapScore(scored[index].title, terms: terms)
        }
        scored.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        let relevant = scored.filter { ($0.score ?? 0) > 0 }
        webHits = Array((relevant.isEmpty ? scored : relevant).prefix(6))
    }

    /// Significant lowercase words (≥3 chars, minus filler) for overlap scoring.
    private static func keywords(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "are", "from", "photo",
                                 "image", "picture", "shows", "showing", "appears", "logo"]
        return Array(Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }))
    }

    /// 0–1 share of the reference terms (weighted by length) present in a title.
    private static func overlapScore(_ title: String, terms: [String]) -> Double {
        let hay = title.lowercased()
        var matched = 0.0, total = 0.0
        for term in terms {
            let weight = Double(term.count)
            total += weight
            if hay.contains(term) { matched += weight }
        }
        return total == 0 ? 0 : matched / total
    }

    private func runVision() async {
        // OCR-first: strong on-screen text → skip the vision model, use the text as identity.
        if hasStrongText {
            vision = .skipped
            return
        }
        guard let provider = await intelligence.activeVisionProvider() else { vision = .skipped; return }
        do {
            let raw = try await provider.describe(image, prompt: Self.visionPrompt)
            let (description, query) = Self.splitVision(raw)
            visionText = description
            visionQuery = query
            vision = description.isEmpty ? .failed : .done
        } catch {
            visionError = error.localizedDescription   // surfaced if nothing else comes through
            vision = .failed
        }
    }

    /// Populate the view from a cached result — no model/web calls.
    private func applyCached(_ entry: IdentifyCache.Entry) {
        visionText = entry.visionText
        ddgAbstract = entry.abstract
        webHits = entry.webHits
        summary = entry.summary
        vision = .done; sources = .done
        synthStarted = true
    }

    private func maybeSynthesize() {
        guard vision.settled, sources.settled, !synthStarted else { return }
        synthStarted = true
        // Code / text / UI captures have no photo subject to identify — point the user to the right
        // tool instead of returning a weak "no subject" answer.
        if let redirect = Self.redirectMessage(for: intent) {
            summary = redirect
            Log.intelligence.notice("⏱ identify redirect (\(intent.rawValue, privacy: .public))")
            return
        }
        Task {
            let tRank = Date()
            rankHits()    // word-overlap ordering of web/community hits before synthesizing
            Log.intelligence.notice("⏱ rank: \(Self.ms(tRank), privacy: .public)")
            await startSynthesis()
        }
    }

    /// For non-subject captures (code / plain text / app UI) Identify isn't the right tool — guide the
    /// user to the actions that are. Returns nil for everything else (normal identification).
    private static func redirectMessage(for intent: IdentifyIntent) -> String? {
        let kind: String
        switch intent {
        case .code: kind = "code"
        case .ui:   kind = "an app screenshot"
        case .text: kind = "mostly text"
        default:    return nil
        }
        return "This looks like \(kind), not a photo to identify. To work with it, use **Copy text**, "
            + "**Ask AI**, **Summarize**, or **Continue in chat** on the selection."
    }

    private func startSynthesis() async {
        let hasAny = !visionText.isEmpty || ddgAbstract != nil || !webHits.isEmpty
            || bestGuess != nil || !entities.isEmpty || hasStrongText
        guard hasAny else {
            // Prefer the real reason the image model failed (e.g. a 404 / non-multimodal model).
            if let visionError {
                synthError = "Image model error: \(visionError)"
            } else if intelligence.effectivePreferred.isLocalKind,
               await !OllamaEndpoint.isReachable(OllamaEndpoint.baseURL) {
                synthError = "Ollama isn't running. Open the Ollama app (or set its server URL under "
                    + "Settings ▸ Intelligence), then try again."
            } else {
                synthError = "No image model is available. Choose one under Settings ▸ Intelligence ▸ "
                    + "Image model (e.g. Ollama (local) or a multimodal cloud model), or enable a source "
                    + "(Web search / Reverse image) in Connectors."
            }
            return
        }

        synthesizing = true
        let prompt = synthesisPrompt()
        synthTask = Task {
            let tSynth = Date()
            var firstToken: Date?
            do {
                for try await delta in intelligence.respond(prompt: prompt, context: nil) {
                    if Task.isCancelled { break }
                    if firstToken == nil { firstToken = Date() }
                    summary += delta
                }
            } catch {
                synthError = error.localizedDescription
            }
            synthesizing = false
            let ftt = firstToken.map { String(format: "%.0fms", $0.timeIntervalSince(tSynth) * 1000) } ?? "—"
            Log.intelligence.notice("⏱ synth: \(Self.ms(tSynth), privacy: .public) (first token \(ftt, privacy: .public))")
            Log.intelligence.notice("⏱ TOTAL: \(Self.ms(pipelineStart), privacy: .public)")
            // Cache the finished result so an identical crop is instant next time.
            if synthError == nil, !summary.isEmpty, !cacheKey.isEmpty, !Task.isCancelled {
                IdentifyCache.set(cacheKey, IdentifyCache.Entry(
                    date: Date(), summary: summary, visionText: visionText,
                    abstract: ddgAbstract, webHits: webHits))
            }
        }
    }

    // MARK: - Helpers

    private var hasStrongText: Bool {
        (ocrText ?? "").filter(\.isLetter).count >= 40
    }

    /// Confidence parsed out of the summary, so it renders as a badge wherever the model wrote it.
    private var confidence: (level: String, color: Color)? {
        guard let range = summary.range(of: "Confidence:\\s*(High|Medium|Low)",
                                        options: [.regularExpression, .caseInsensitive]) else { return nil }
        let level = summary[range].replacingOccurrences(of: "Confidence:", with: "",
                                                        options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces).capitalized
        let color: Color = level == "High" ? .green : (level == "Medium" ? .yellow : .orange)
        return (level, color)
    }

    /// Summary with the "Confidence: …" phrase stripped (shown as a badge instead).
    private var displaySummary: String {
        summary.replacingOccurrences(of: "\\n*\\s*Confidence:\\s*(High|Medium|Low)\\.?",
                                     with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildQuery() -> String {
        // Prefer the model's keyword line; else condense the description / OCR into a search term.
        if !visionQuery.isEmpty { return visionQuery }
        return Self.condense(!visionText.isEmpty ? visionText : (ocrText ?? ""))
    }

    /// Strip lead-ins ("the image shows…") and stopwords, keep a few significant words — the web
    /// sources want a search term, not a sentence.
    private static func condense(_ text: String) -> String {
        let leadIns = ["the image shows", "this image shows", "the photo shows", "it appears to be",
                       "this is a", "this is an", "this is", "a photo of", "an image of",
                       "the main subject is", "shows a", "shows an"]
        var s = text.lowercased()
        for lead in leadIns where s.hasPrefix(lead) { s = String(s.dropFirst(lead.count)); break }
        let stop: Set<String> = ["a", "an", "the", "of", "in", "on", "with", "and", "is", "are",
                                 "to", "for", "that", "it", "image", "photo", "shows", "showing"]
        let words = s.split(whereSeparator: { ".,;:\n!?".contains($0) || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !stop.contains($0) }
            .prefix(6)
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split the vision output into (description, search-query) using the trailing "Search:" line.
    private static func splitVision(_ raw: String) -> (String, String) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let idx = lines.lastIndex(where: { $0.lowercased().hasPrefix("search:") }) {
            let query = lines[idx].dropFirst("search:".count).trimmingCharacters(in: .whitespaces)
            let description = lines[..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (description, String(query.prefix(80)))
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    private static let visionPrompt = """
    What is shown in this image? Identify the main subject — object, food, place, landmark, logo, \
    brand, plant/animal, or product. If you recognize a specific brand, place, or item, name it. \
    Be concise (2–3 sentences). Then on a new line write "Search:" followed by 3–6 keywords best \
    for a web search (brand, model, object, or place names).
    """

    private func synthesisPrompt() -> String {
        let related = webHits.prefix(6)
            .map { hit -> String in
                var line = "- [\(hit.source)] \(hit.title)"
                if let snippet = hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !snippet.isEmpty {
                    line += "\n  \(snippet.prefix(280))"
                }
                return line
            }
            .joined(separator: "\n")
        let entityList = entities.isEmpty ? "(none)" : entities.prefix(6).joined(separator: ", ")

        return """
        Help the user identify the MAIN SUBJECT of what they captured (a person, place, object, \
        product, artwork, scene from a film…). Fuse the evidence below into a short, helpful \
        explanation of what it is, plus useful context.

        Rules:
        - The "Visual best-guess" and "Recognized entities" come from reverse-image search — when \
        present they are the STRONGEST signal; trust them over the generic visual description.
        - If the best-guess and entities are BOTH "(none)", reverse-image found no specific match. \
        Do NOT describe the generic category (e.g. don't explain what "a human" or "a photograph" \
        is). Instead say plainly that you couldn't identify the specific subject, briefly note what \
        you can see, and suggest the user try a clearer or wider capture. Use "Confidence: Low".
        - Pages that are stock-photo, marketplace, or Pinterest-style results only mean the image \
        is widely used — do NOT identify the subject as those sites, and do NOT invent a place, \
        venue, or scene from incidental background details (lighting, walls, towels, etc.).
        - Confidence discipline: say "Confidence: High" ONLY when a specific named identity is \
        corroborated by the visual best-guess, a matching page title, or the encyclopedia. If you \
        are inferring only from the generic visual description, use "Confidence: Low" (Medium at \
        most), and say plainly that you're unsure.

        Write 2–4 sentences, then on a new line write exactly "Confidence: High" (or Medium / Low).
        \(intent.label.isEmpty ? "" : "\nLikely category (hint, not authoritative): \(intent.label).")

        Visual best-guess: \(bestGuess?.isEmpty == false ? bestGuess! : "(none)")

        Recognized entities: \(entityList)

        On-screen text: \(ocrText?.isEmpty == false ? ocrText! : "(none)")

        Visual analysis: \(visionText.isEmpty ? "(no vision model used)" : visionText)

        Encyclopedia: \(ddgAbstract ?? "(none)")

        Related web/community results:
        \(related.isEmpty ? "(none)" : related)
        """
    }
}

/// A source result rendered as a clean card row: favicon + title (2 lines) + domain/source ·
/// match%, with a hover highlight — a familiar search-result layout.
private struct SourceRow: View {
    let domain: String
    let title: String
    let subtitle: String
    let url: URL?
    let score: Double?
    @State private var hovering = false

    var body: some View {
        // Open on the next runloop tick: doing it synchronously inside the button action — while
        // this view is hosted in a borderless floating NSPanel — deactivates the app and can
        // re-enter the SwiftUI update mid-click (a stack-overflow crash). Deferring breaks that.
        Button {
            guard let url else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Favicon(domain: domain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(subtitle).lineLimit(1)
                        if let score {
                            Text("·").opacity(0.5)
                            Text("\(Int(score * 100))% match").foregroundStyle(matchColor)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.forward").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var matchColor: Color {
        guard let score else { return .secondary }
        return score >= 0.6 ? .green : (score >= 0.45 ? .yellow : .secondary)
    }
}

/// Domain favicon via DuckDuckGo's icon service (privacy-friendly), with a globe fallback. In
/// local-only mode we never reach out for the icon — the globe placeholder stands in.
private struct Favicon: View {
    let domain: String

    var body: some View {
        Group {
            if domain.isEmpty || PrivacyMode.localOnly {
                placeholder
            } else {
                AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.secondary)
    }
}
