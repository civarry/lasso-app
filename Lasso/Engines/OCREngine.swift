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

        // Preserve reading order: top-to-bottom (Vision y is bottom-up, so sort descending).
        lines.sort { $0.boundingBox.midY > $1.boundingBox.midY }
        let text = lines.map(\.string).joined(separator: "\n")
        return OCRResult(text: text, lines: lines)
    }
}
