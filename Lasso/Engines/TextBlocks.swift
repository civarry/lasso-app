import Foundation
import CoreGraphics

/// A run of OCR lines that belong together: a wrapped paragraph, a heading, a label. The unit the
/// translation overlay draws, the unit of context sent to a model, and one paragraph in the reading
/// view. A visual line is an artifact of the screenshot's column width; a block is the text.
struct TextBlock: Identifiable, Sendable {
    /// The first line's id, so the same lines always group into the same ids: the prewarmer's cache
    /// and the overlay agree on which block a cached translation belongs to.
    let id: UUID
    let lineIDs: [UUID]      // the OCR lines that make it up, in reading order
    let text: String         // lines joined, hyphenation repaired
    let frame: CGRect        // union of the line boxes, in normalized crop coordinates
    let language: Locale.Language?   // detected per block, not per selection
}

enum TextBlocks {
    /// Group OCR lines (in reading order) into blocks. Two consecutive lines join when their
    /// horizontal ranges overlap by more than half the narrower one, the gap between them is under
    /// 0.6× the taller line's height, and their heights are within 40% of each other. Everything else
    /// starts a new block.
    static func group(_ lines: [OCRLine]) -> [TextBlock] {
        var runs: [[OCRLine]] = []
        for line in lines {
            if let prev = runs.last?.last, joins(prev, line) {
                runs[runs.count - 1].append(line)
            } else {
                runs.append([line])
            }
        }
        let texts = runs.map { joinedText($0.map(\.string)) }
        let languages = languages(for: texts)
        return runs.indices.map { i in
            let run = runs[i]
            let frame = run.dropFirst().reduce(run[0].boundingBox) { $0.union($1.boundingBox) }
            return TextBlock(id: run[0].id, lineIDs: run.map(\.id), text: texts[i], frame: frame,
                             language: languages[i])
        }
    }

    /// Below this, NaturalLanguage's guess for a Latin block is not trusted on its own.
    static let confidentLatin = 0.9

    /// Per-block languages. A Latin block the detector is unsure of (short labels, ids, "Invoice
    /// details:") takes the language most of the selection's confident Latin text is in, so one
    /// misread label doesn't turn an English page into "Mixed · English, Romanian". A confident block
    /// keeps its own language, so a real French paragraph on an English page stays French.
    static func languages(for texts: [String]) -> [Locale.Language?] {
        let detections = texts.map(LanguageDetect.detection(of:))
        let isLatin = texts.map { LanguageDetect.dominantScript($0) == .latin }

        var weight: [String: (lang: Locale.Language, chars: Int)] = [:]
        for (i, d) in detections.enumerated() {
            guard isLatin[i], let d, d.confidence >= confidentLatin else { continue }
            let key = d.language.minimalIdentifier
            weight[key] = (d.language, (weight[key]?.chars ?? 0) + texts[i].count)
        }
        let selectionLatin = weight.values.max { $0.chars < $1.chars }?.lang

        return detections.indices.map { i in
            guard let d = detections[i] else { return nil }
            if isLatin[i], d.confidence < confidentLatin, let selectionLatin { return selectionLatin }
            return d.language
        }
    }

    /// Vision boxes are normalized with a bottom-left origin, so the next line down has a smaller y.
    static func joins(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let ra = a.boundingBox, rb = b.boundingBox
        let overlap = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX)
        guard overlap > 0.5 * min(ra.width, rb.width) else { return false }
        let taller = max(ra.height, rb.height), shorter = min(ra.height, rb.height)
        guard taller > 0, shorter >= 0.6 * taller else { return false }
        guard rb.midY < ra.midY else { return false }          // b must be below a
        let gap = ra.minY - rb.maxY
        return gap < 0.6 * taller
    }

    /// Join lines into running text: a trailing hyphen joins the next line without a space, and two
    /// CJK characters meet without one (those scripts don't separate words).
    static func joinedText(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if out.isEmpty { out = line; continue }
            if out.hasSuffix("-"), out.count > 1,
               out.dropLast().last?.isLetter == true, line.first?.isLetter == true {
                out.removeLast()
                out += line
            } else if isCJK(out.unicodeScalars.last), isCJK(line.unicodeScalars.first) {
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        if let s = LanguageDetect.script(for: scalar) { return s == .han || s == .kana }
        return (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

/// Which blocks get translated, and from what. Replaces the old "one dominant source language per
/// selection" model: each block carries its own language, so a selection with English *and*
/// Japanese translates both, and there is no losing language.
enum TranslationPlan {
    /// The language a block is treated as: the manual override when set (the escape hatch for bad
    /// detection), else its own detected language.
    static func source(of block: TextBlock, override: Locale.Language?) -> Locale.Language? {
        guard block.text.contains(where: \.isLetter) else { return nil }
        return override ?? block.language
    }

    /// Whether a block needs translating into `target`. A block already in the target language is
    /// left alone, and so is one with no recognizable language.
    static func needsTranslation(_ block: TextBlock, target: Locale.Language,
                                 override: Locale.Language?) -> Bool {
        guard let source = source(of: block, override: override) else { return false }
        return base(source) != base(target)
    }

    /// Translatable blocks grouped by source language, largest group first. Apple's Translation
    /// framework takes one source per session, so pass 1 runs one session per group.
    static func groups(_ blocks: [TextBlock], target: Locale.Language,
                       override: Locale.Language?) -> [(source: Locale.Language, blocks: [TextBlock])] {
        var order: [String] = []
        var byID: [String: (source: Locale.Language, blocks: [TextBlock])] = [:]
        for block in blocks where needsTranslation(block, target: target, override: override) {
            guard let src = source(of: block, override: override) else { continue }
            let key = src.minimalIdentifier
            if byID[key] == nil { order.append(key); byID[key] = (src, []) }
            byID[key]?.blocks.append(block)
        }
        return order.compactMap { byID[$0] }
            .enumerated()
            .sorted { ($0.element.blocks.count, -$0.offset) > ($1.element.blocks.count, -$1.offset) }
            .map(\.element)
    }

    /// Every language found in the selection, most text first, one entry per displayed name.
    static func detectedLanguages(_ blocks: [TextBlock],
                                  name: (Locale.Language) -> String) -> [Locale.Language] {
        var weight: [String: Int] = [:]
        var first: [String: (index: Int, lang: Locale.Language)] = [:]
        for (i, block) in blocks.enumerated() {
            guard let lang = block.language else { continue }
            let key = name(lang)
            weight[key, default: 0] += block.text.count
            if first[key] == nil { first[key] = (i, lang) }
        }
        return first.sorted { a, b in
            let wa = weight[a.key] ?? 0, wb = weight[b.key] ?? 0
            return wa != wb ? wa > wb : a.value.index < b.value.index
        }.map(\.value.lang)
    }

    /// The source chip: what was actually found, never a permanent placeholder. `detected` nil means
    /// detection hasn't run yet (the only time "Detecting…" is allowed).
    static func sourceLabel(detected: [Locale.Language]?, override: Locale.Language?,
                            name: (Locale.Language) -> String) -> String {
        if let override { return name(override) }
        guard let detected else { return "Detecting…" }
        switch detected.count {
        case 0: return "Unknown source"
        case 1: return "Detected · \(name(detected[0]))"
        default:
            let shown = detected.prefix(3).map(name).joined(separator: ", ")
            let more = detected.count > 3 ? " +\(detected.count - 3)" : ""
            return "Mixed · \(shown)\(more)"
        }
    }

    /// The whole translation as prose: one paragraph per block, blank lines between, the OCR's line
    /// breaks gone. What the reading view shows and what Copy puts on the pasteboard.
    static func readingText(_ blocks: [TextBlock], text: (TextBlock) -> String?) -> String {
        blocks.compactMap { text($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func base(_ lang: Locale.Language) -> String {
        LanguageDetect.baseCode(lang.languageCode?.identifier ?? lang.minimalIdentifier)
    }
}
