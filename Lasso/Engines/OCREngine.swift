import CoreGraphics
import Foundation
import Vision

/// A single recognized line plus its normalized bounding box (Vision coords: origin bottom-left).
struct OCRLine: Sendable, Identifiable {
    let id = UUID()
    let string: String
    let boundingBox: CGRect
}

struct OCRResult: Sendable {
    let text: String
    let lines: [OCRLine]

    var isEmpty: Bool { text.isEmpty }
    static let empty = OCRResult(text: "", lines: [])
}

/// On-device text recognition via Vision's modern Swift `RecognizeTextRequest` API.
/// Defaults to Traditional Chinese + English (mixed-script — Spec §7).
actor OCREngine {
    func recognize(
        _ image: CGImage,
        languages: [String] = ["zh-Hant", "en-US"]
    ) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }

        let observations = try await request.perform(on: image)

        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(OCRLine(string: candidate.string,
                                 boundingBox: observation.boundingBox.cgRect))
        }

        let ordered = Self.readingOrdered(lines)
        let text = ordered.map(\.string).joined(separator: "\n")
        return OCRResult(text: text, lines: ordered)
    }

    /// Order lines into natural reading order. Vision returns lines roughly top-to-bottom, which
    /// interleaves columns on multi-column layouts (e.g. a headline on the left with boxes on the
    /// right). When a clean vertical gutter splits the lines into two non-overlapping columns, read
    /// the left column fully then the right; otherwise fall back to plain top-to-bottom. Purely
    /// geometric — reorders only, never rewrites or drops a line.
    static func readingOrdered(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count >= 4, let gutter = twoColumnGutter(lines) else {
            return topToBottom(lines)
        }
        let left = lines.filter { $0.boundingBox.maxX <= gutter }
        let right = lines.filter { $0.boundingBox.minX >= gutter }
        return topToBottom(left) + topToBottom(right)
    }

    /// Top-to-bottom (Vision y is bottom-up, so sort by descending midY).
    private static func topToBottom(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    }

    /// Find an x in the central band that cleanly separates the lines into a left and right column
    /// with NO line straddling it — so the split can never lose or duplicate text. Returns nil when
    /// there's no such clean two-column split (i.e. ordinary single-column text), preferring the
    /// most balanced gutter when several qualify.
    private static func twoColumnGutter(_ lines: [OCRLine]) -> CGFloat? {
        var best: (x: CGFloat, balance: Int)?
        var x: CGFloat = 0.30
        while x <= 0.70 {
            let left = lines.filter { $0.boundingBox.maxX <= x }.count
            let right = lines.filter { $0.boundingBox.minX >= x }.count
            if left + right == lines.count, left >= 2, right >= 2 {
                let balance = min(left, right)
                if best == nil || balance > best!.balance { best = (x, balance) }
            }
            x += 0.01
        }
        return best?.x
    }
}
