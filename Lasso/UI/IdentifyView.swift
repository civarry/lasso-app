import SwiftUI
import AppKit

/// The Identify pipeline in a floating card. OCR-first: if the selection has strong text we skip
/// the vision model and use the text; otherwise we run the local vision model. In parallel (when
/// "Web lookup" is on) we reverse-search TinEye and query DuckDuckGo + Reddit, then fuse everything
/// and synthesize a summary with the user's chosen provider (Apple on-device or Ollama).
struct IdentifyView: View {
    let image: CGImage
    let ocrText: String?
    let intelligence: IntelligenceCoordinator

    @AppStorage("imageSearch.enabled") private var webEnabled = false
    @AppStorage("ui.resultTextScale") private var textScale = 1.0

    private enum Stage { case running, done, failed, skipped
        var settled: Bool { self != .running }
    }

    @State private var vision: Stage = .running
    @State private var visionText = ""
    @State private var visionQuery = ""
    @State private var tineye: Stage = .running
    @State private var matches: [ImageMatch] = []
    @State private var web: Stage = .running
    @State private var ddgAbstract: String?
    @State private var webHits: [WebSourcesProvider.Hit] = []

    @State private var summary = ""
    @State private var synthStarted = false
    @State private var synthesizing = false
    @State private var synthError: String?
    @State private var synthTask: Task<Void, Never>?

    private var busy: Bool { !(vision.settled && tineye.settled && web.settled) || synthesizing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusLine

            if !summary.isEmpty {
                ScrollView {
                    MarkdownView(text: displaySummary, fontSize: resultTextBaseSize * textScale)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                if let confidence {
                    Label("Confidence: \(confidence.level)", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(confidence.color)
                }
            } else if let synthError {
                Label(synthError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            if !visionText.isEmpty {
                DisclosureGroup("Visual analysis") {
                    Text(visionText).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }

            if !matches.isEmpty || !webHits.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !matches.isEmpty {
                            sectionLabel("Image appears on")
                            ForEach(matches.prefix(8)) { match in
                                MatchRow(match: match) { NSWorkspace.shared.open($0) }
                            }
                        }
                        if !webHits.isEmpty {
                            sectionLabel("Related")
                            ForEach(webHits.prefix(8)) { hit in WebHitRow(hit: hit) }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if webEnabled {
                Label("Web lookup used (TinEye / DuckDuckGo / Reddit) — leaves your Mac.",
                      systemImage: "arrow.up.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .background {
            if webEnabled {
                TinEyeWorker(image: image) { found in
                    matches = found   // show immediately
                    Task {
                        let enriched = await Self.enrichTitles(found)
                        matches = enriched
                        tineye = .done
                        maybeSynthesize()
                    }
                }
                .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
            }
        }
        .task { await runPipeline() }
        .task { await tineyeTimeout() }
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
        if !(vision.settled && tineye.settled && web.settled) {
            let parts = [vision == .running ? "Looking at image" : nil,
                         (tineye == .running || web == .running) ? "Searching the web" : nil]
                .compactMap { $0 }
            Text(parts.joined(separator: " · ") + "…").font(.caption).foregroundStyle(.secondary)
        } else if synthesizing && summary.isEmpty {
            Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        await runVision()
        await runWebSources()
        await rankHits()
        maybeSynthesize()
    }

    /// Rank Related hits by semantic similarity to the identity (nomic-embed-text), then keep the
    /// relevant ones — so we show the likely article, not generic keyword noise.
    private func rankHits() async {
        guard !webHits.isEmpty else { return }
        let reference = !visionQuery.isEmpty ? visionQuery
            : (!visionText.isEmpty ? visionText : (ocrText ?? ""))
        guard !reference.isEmpty else { return }

        let embedder = OllamaEmbeddings()
        let texts = [reference] + webHits.map(\.title)
        guard let vectors = await embedder.embed(texts), vectors.count == texts.count else { return }

        let refVec = vectors[0]
        var scored = webHits
        for index in scored.indices {
            scored[index].score = OllamaEmbeddings.cosine(refVec, vectors[index + 1])
        }
        scored.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        let relevant = scored.filter { ($0.score ?? 0) >= 0.40 }
        webHits = Array((relevant.isEmpty ? scored : relevant).prefix(6))
    }

    private func runVision() async {
        // OCR-first: strong on-screen text → skip the vision model, use the text as identity.
        if hasStrongText {
            vision = .skipped
            return
        }
        let provider = OllamaVisionProvider(model: intelligence.visionModel)
        guard await provider.isAvailable() else { vision = .skipped; return }
        do {
            let raw = try await provider.describe(image, prompt: Self.visionPrompt)
            let (description, query) = Self.splitVision(raw)
            visionText = description
            visionQuery = query
            vision = description.isEmpty ? .failed : .done
        } catch {
            vision = .failed
        }
    }

    private func runWebSources() async {
        guard webEnabled else { web = .skipped; tineye = .skipped; return }
        let query = buildQuery()
        guard !query.isEmpty else { web = .skipped; return }
        let result = await WebSourcesProvider().lookup(query)
        ddgAbstract = result.abstract
        webHits = result.hits
        web = .done
    }

    private func tineyeTimeout() async {
        guard webEnabled else { return }
        try? await Task.sleep(for: .seconds(22))
        if tineye == .running { tineye = .failed; maybeSynthesize() }
    }

    private func maybeSynthesize() {
        guard vision.settled, tineye.settled, web.settled, !synthStarted else { return }
        synthStarted = true

        let hasAny = !visionText.isEmpty || !matches.isEmpty || ddgAbstract != nil
            || !webHits.isEmpty || hasStrongText
        guard hasAny else {
            synthError = "Not enough to go on. Pull a vision model "
                + "(`ollama pull \(intelligence.visionModel)`) or enable Web lookup in Settings."
            return
        }

        synthesizing = true
        let prompt = synthesisPrompt()
        synthTask = Task {
            do {
                for try await delta in intelligence.respond(prompt: prompt, context: nil) {
                    if Task.isCancelled { break }
                    summary += delta
                }
            } catch {
                synthError = error.localizedDescription
            }
            synthesizing = false
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

    /// Fetch the page <title> of the top matches — that's the real "detective" signal (e.g. the
    /// article headline featuring the image), far richer than the bare domain.
    private static func enrichTitles(_ matches: [ImageMatch]) async -> [ImageMatch] {
        var result = matches
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, match) in matches.enumerated() where index < 4 {
                guard let url = match.pageURL else { continue }
                group.addTask { (index, await fetchTitle(url)) }
            }
            for await (index, title) in group {
                if let title, index < result.count { result[index].title = title }
            }
        }
        return result
    }

    private static func fetchTitle(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let head = data.prefix(120_000)
        let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
        guard let html,
              let open = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let title = html[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(160))
    }

    private func buildQuery() -> String {
        // Prefer the model's keyword line; else condense the description / OCR into a search term.
        if !visionQuery.isEmpty { return visionQuery }
        return Self.condense(!visionText.isEmpty ? visionText : (ocrText ?? ""))
    }

    /// Strip lead-ins ("the image shows…") and stopwords, keep a few significant words — DDG/Reddit
    /// want a search term, not a sentence.
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
        let imageSites = matches.prefix(6)
            .map { "- \($0.domain)\($0.title.map { " — \($0)" } ?? "")" }
            .joined(separator: "\n")
        let related = webHits.prefix(6)
            .map { "- [\($0.source)] \($0.title)" }
            .joined(separator: "\n")

        return """
        Help the user identify something they captured on screen. Fuse the evidence below into a \
        short, helpful explanation: what it most likely is, plus useful context (brand, place, what \
        it's for). Prefer specifics from the source page titles over generic guesses. Write 2–4 \
        sentences, then on a new line write exactly "Confidence: High" (or Medium / Low). If \
        signals conflict or are weak, say so.

        On-screen text: \(ocrText?.isEmpty == false ? ocrText! : "(none)")

        Visual analysis: \(visionText.isEmpty ? "(no vision model used)" : visionText)

        Encyclopedia (DuckDuckGo): \(ddgAbstract ?? "(none)")

        Image appears on these sites:
        \(imageSites.isEmpty ? "(none)" : imageSites)

        Related web/community results:
        \(related.isEmpty ? "(none)" : related)
        """
    }
}

private struct WebHitRow: View {
    let hit: WebSourcesProvider.Hit
    @State private var hovering = false

    var body: some View {
        Button { if let url = hit.url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 8) {
                Image(systemName: hit.source.hasPrefix("r/") ? "bubble.left.and.bubble.right" : "globe")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title).font(.callout).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(hit.source)
                        if let score = hit.score {
                            Text("· \(Int(score * 100))% match")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.white.opacity(hovering ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
