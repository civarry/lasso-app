import Foundation

/// Small, pure helpers for reading what a model actually wrote. Nonisolated and dependency-free so
/// both the harness (off the main actor) and `ChatController` (on it) can share one implementation.
enum ModelText {
    /// Strip `<think>…</think>` reasoning blocks (Qwen3 / DeepSeek style) so parsers see only the
    /// model's real output. An unterminated block drops everything after it: a model that is still
    /// thinking has not answered yet.
    static func stripThoughtBlocks(from text: String) -> String {
        var remaining = text
        var result = ""
        while let start = remaining.range(of: "<think>", options: [.caseInsensitive]) {
            result += remaining[..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.range(of: "</think>", options: [.caseInsensitive]) else {
                remaining = ""
                break
            }
            remaining = String(afterStart[end.upperBound...])
        }
        result += remaining
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the first balanced JSON object out of a model reply. Small models wrap JSON in prose or
    /// ```json fences even when asked not to, and a backend's JSON mode only guarantees the *schema*,
    /// not that the transport left it unadorned. Brace counting is string-aware so a `}` inside a
    /// value can't end the object early.
    static func firstJSONObject(in raw: String) -> [String: Any]? {
        let text = stripThoughtBlocks(from: raw)
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if escaped {
                escaped = false
            } else if c == "\\", inString {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil }

        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Read a string field, treating empty and the model's "NONE" placeholder as absent.
    static func string(_ object: [String: Any], _ key: String) -> String? {
        let raw: String?
        switch object[key] {
        case let s as String: raw = s
        case let n as NSNumber: raw = n.stringValue
        default: raw = nil
        }
        guard let value = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`")),
              !value.isEmpty, value.uppercased() != "NONE", value.lowercased() != "null"
        else { return nil }
        return value
    }

    /// Read a boolean field, tolerating the strings and numbers small models emit instead of `true`.
    static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        switch object[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
