import Foundation
import NaturalLanguage

/// Robust language detection for short, mixed OCR text. NaturalLanguage alone hallucinates on tiny
/// strings (e.g. "愛 Love" → "Italian"), so we lead with **Unicode script** detection (Han →
/// Chinese, Hangul → Korean, …) and only trust NaturalLanguage when its guess agrees with the
/// dominant script. Lines are translated only when their script matches the source — so a Latin word
/// like "Love" is never "translated from Chinese".
enum LanguageDetect {
    enum Script: Hashable { case han, kana, hangul, cyrillic, arabic, thai, devanagari, latin }

    static func baseCode(_ identifier: String) -> String {
        String(identifier.split(separator: "-").first ?? "").lowercased()
    }

    static func script(for scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return .han
        case 0x3040...0x30FF: return .kana                 // hiragana + katakana
        case 0xAC00...0xD7AF, 0x1100...0x11FF: return .hangul
        case 0x0400...0x04FF: return .cyrillic
        case 0x0600...0x06FF, 0x0750...0x077F: return .arabic
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
        default: return nil                                // digits, punctuation, spaces, emoji
        }
    }

    static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars { if let s = script(for: scalar) { counts[s, default: 0] += 1 } }
        if (counts[.kana] ?? 0) > 0 { return .kana }       // kana strongly implies Japanese
        return counts.max { $0.value < $1.value }?.key
    }

    /// The script a language is written in (for matching lines to the source language).
    static func script(forLanguage base: String) -> Script {
        switch base {
        case "zh": return .han
        case "ja": return .kana
        case "ko": return .hangul
        case "ru", "uk", "be", "bg", "sr", "mk": return .cyrillic
        case "ar", "fa", "ur": return .arabic
        case "th": return .thai
        case "hi", "mr", "ne": return .devanagari
        default: return .latin
        }
    }

    private static func defaultLanguage(for script: Script, sampleText: String) -> String? {
        switch script {
        case .han: return "zh-Hans"
        case .kana: return "ja"
        case .hangul: return "ko"
        case .cyrillic: return "ru"
        case .arabic: return "ar"
        case .thai: return "th"
        case .devanagari: return "hi"
        case .latin:
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sampleText)
            return recognizer.dominantLanguage?.rawValue
        }
    }

    /// Dominant **non-target** language across `text`. Script-first; NaturalLanguage is trusted only
    /// when it agrees with the dominant non-target script (which preserves zh-Hant vs zh-Hans, etc.).
    /// Returns nil when everything is already in the target's script.
    static func dominantNonTargetLanguage(in text: String, targetBase: String) -> Locale.Language? {
        let targetScript = script(forLanguage: targetBase)
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars { if let s = script(for: scalar) { counts[s, default: 0] += 1 } }

        if (counts[.kana] ?? 0) > 0, targetScript != .kana {
            return Locale.Language(identifier: "ja")
        }
        guard let nonTargetScript = counts.filter({ $0.key != targetScript })
            .max(by: { $0.value < $1.value })?.key else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let nl = recognizer.dominantLanguage?.rawValue,
           baseCode(nl) != targetBase,
           script(forLanguage: baseCode(nl)) == nonTargetScript {
            return Locale.Language(identifier: nl)         // NL agrees → keep its variant
        }
        if let code = defaultLanguage(for: nonTargetScript, sampleText: text) {
            return Locale.Language(identifier: code)        // NL hallucinated → script default
        }
        return nil
    }

    /// Whether a line should be translated, given the chosen source + target. A line is translated
    /// only when its script matches the source's script and it isn't confidently already in the
    /// target language — so mixed-script lines (e.g. a Latin word in Chinese text) pass through.
    static func shouldTranslate(_ text: String, sourceBase: String, targetBase: String) -> Bool {
        guard text.contains(where: \.isLetter) else { return false }
        let sourceScript = script(forLanguage: sourceBase)
        let lineScript = dominantScript(text) ?? .latin
        let matches = lineScript == sourceScript || (sourceBase == "ja" && lineScript == .han)
        guard matches else { return false }

        // Same-script refinement (e.g. English inside a French selection): skip lines confidently in
        // the target. Only for longer Latin text, where NaturalLanguage is reliable.
        if sourceScript == .latin, text.count >= 4 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let top = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
               baseCode(top.key.rawValue) == targetBase, top.value >= 0.85 {
                return false
            }
        }
        return true
    }
}
