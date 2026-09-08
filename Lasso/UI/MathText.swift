import Foundation

/// Converts LaTeX math into readable Unicode text.
///
/// The system prompt asks models to write formulas as plain text, and they ignore it — any question
/// about a formula comes back wrapped in `\[ … \]` with `\frac`, `\mathbf` and `\cdot` inside. That
/// used to reach the screen as literal markup, which is worse than no formatting at all.
///
/// Typesetting it properly would mean a math engine: KaTeX in a WebView is ruled out (the app avoids
/// WebViews to stay lightweight), and a native typesetter is a large dependency for a menu
/// bar utility. So this does the next best thing — the same repair-not-rejection rule the Markdown
/// parser follows. `\frac{A \cdot B}{\|A\| \|B\|}` becomes `(A · B) / (‖A‖ ‖B‖)`, which is what a
/// person would write by hand, and unknown commands degrade to their own name rather than vanishing.
///
/// Pure and nonisolated, so it can be tested without SwiftUI.
enum MathText {

    // MARK: - Delimiters

    /// A display-math region: `\[ … \]`, `$$ … $$`, or a `\begin{equation}` environment.
    struct Display: Equatable {
        var latex: String
        /// False when the closing delimiter hasn't arrived yet (normal mid-stream).
        var closed: Bool
    }

    /// If `line` opens a display-math region, the opening delimiter's length and its closer.
    static func displayOpener(_ line: String) -> (open: String, close: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\\[") { return ("\\[", "\\]") }
        if t.hasPrefix("$$") { return ("$$", "$$") }
        for env in ["equation*", "equation", "align*", "align", "aligned", "gather*", "gather"]
        where t.hasPrefix("\\begin{\(env)}") {
            return ("\\begin{\(env)}", "\\end{\(env)}")
        }
        return nil
    }

    /// Rewrite the inline math spans in a line of prose: `\( … \)` always, and `$ … $` only when the
    /// content looks like math. The `$` guard matters — "it costs $5 to $10 per run" is prose, and
    /// treating it as math would silently mangle the sentence.
    static func rewriteInline(_ text: String) -> String {
        var out = rewriteSpans(text, open: "\\(", close: "\\)") { _, _ in true }
        out = rewriteSpans(out, open: "$", close: "$", accept: isMathDollarSpan)
        return out
    }

    /// Decide whether `$…$` is a formula or someone's money.
    ///
    /// A LaTeX command, superscript or subscript inside settles it. Failing that, the only other
    /// thing worth claiming is a bare quantity — `$-1$ to `$1$` in "ranges from −1 to 1" — and only
    /// when nothing runs on directly after the closing delimiter, so "it costs $5-$10" (whose span
    /// would be "5-") and "$5 to $10" (whose span contains spaces) are both left as written.
    private static func isMathDollarSpan(_ body: String, next: Character?) -> Bool {
        if body.contains("\\") || body.contains("^") || body.contains("_") { return true }
        if let next, next.isLetter || next.isNumber || next == "$" { return false }
        if body.count == 1, body.first?.isLetter == true { return true }
        var digits = Substring(body)
        if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func rewriteSpans(_ text: String, open: String, close: String,
                                     accept: (String, Character?) -> Bool) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: open) {
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: close) else { break }
            let body = String(afterOpen[..<end.lowerBound])
            let following = afterOpen[end.upperBound...].first
            guard accept(body, following) else {
                result += rest[..<start.upperBound]
                rest = rest[start.upperBound...]
                continue
            }
            result += rest[..<start.lowerBound] + render(body)
            rest = afterOpen[end.upperBound...]
        }
        return result + rest
    }

    // MARK: - Rendering

    /// Convert a LaTeX expression to Unicode text.
    static func render(_ latex: String) -> String {
        var parser = Parser(Array(latex))
        return collapseSpaces(parser.run())
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func run(until stop: Character? = nil) -> String {
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if let stop, c == stop { break }
                switch c {
                case "\\":
                    out += command()
                case "{":
                    i += 1
                    out += run(until: "}")
                    if i < chars.count { i += 1 }        // closing brace
                case "}":
                    i += 1                               // unmatched — drop it
                case "^", "_":
                    i += 1
                    out += script(superscript: c == "^", of: argument())
                case "&":
                    i += 1                               // an alignment marker, not content
                    out += " "
                default:
                    i += 1
                    out.append(c)
                }
            }
            return out
        }

        /// One argument: a braced group, a command, or a single character.
        mutating func argument() -> String {
            guard i < chars.count else { return "" }
            if chars[i] == "{" {
                i += 1
                let body = run(until: "}")
                if i < chars.count { i += 1 }
                return body
            }
            if chars[i] == "\\" { return command() }
            let c = chars[i]
            i += 1
            return String(c)
        }

        mutating func command() -> String {
            i += 1                                       // the backslash
            guard i < chars.count else { return "" }

            // A non-letter after the backslash is an escape or spacing command.
            guard chars[i].isLetter else {
                let c = chars[i]
                i += 1
                switch c {
                case "\\": return "\n"                   // row break inside an environment
                case ",", ";", ":", "!", " ": return " "
                case "|": return "‖"
                default: return String(c)                // \{ \} \% \$ → the character itself
                }
            }

            var name = ""
            while i < chars.count, chars[i].isLetter {
                name.append(chars[i])
                i += 1
            }

            switch name {
            case "frac", "dfrac", "tfrac", "binom":
                let numerator = argument()
                let denominator = argument()
                if name == "binom" { return "C(\(numerator), \(denominator))" }
                return "\(group(numerator))/\(group(denominator))"
            case "sqrt":
                // An optional index: \sqrt[3]{x}.
                var index = ""
                if i < chars.count, chars[i] == "[" {
                    i += 1
                    index = run(until: "]")
                    if i < chars.count { i += 1 }
                }
                let body = argument()
                return index.isEmpty ? "√\(group(body))" : "\(index)√\(group(body))"
            case "text", "mathrm", "mathbf", "mathit", "mathbb", "mathcal", "mathsf", "boldsymbol",
                 "operatorname", "textbf", "textit", "hat", "bar", "vec", "tilde":
                return argument()
            case "begin", "end":
                _ = argument()                           // the environment name
                return ""
            case "left", "right", "displaystyle", "limits", "nolimits", "quad", "qquad":
                return name == "quad" || name == "qquad" ? " " : ""
            default:
                if let symbol = Self.symbols[name] { return symbol }
                // Unknown command: keep its name, and read a braced argument as a call. A reader can
                // follow "coth(x)"; they cannot follow a silently deleted term.
                if i < chars.count, chars[i] == "{" { return "\(name)(\(argument()))" }
                return name
            }
        }

        /// Parenthesise a fraction part only when it isn't already a single term.
        private func group(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("(") && t.hasSuffix(")") { return t }
            let needsParens = t.contains(" ") || t.contains("/") || t.contains("+") || t.contains("-")
            return needsParens ? "(\(t))" : t
        }

        /// Unicode super/subscript when every character has one, else an explicit `^(…)`.
        private func script(superscript: Bool, of arg: String) -> String {
            let table = superscript ? Self.superscripts : Self.subscripts
            var mapped = ""
            for c in arg {
                guard let m = table[c] else {
                    return arg.count == 1 ? "\(superscript ? "^" : "_")\(arg)"
                                          : "\(superscript ? "^" : "_")(\(arg))"
                }
                mapped.append(m)
            }
            return mapped
        }

        static let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
            "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
            "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ",
            "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
            "z": "ᶻ", "T": "ᵀ",
        ]

        static let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
            "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
            "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        ]

        /// The commands that actually show up in model output about vectors, probability and
        /// attention. Anything missing falls through to its own name, so the gap reads as a word
        /// rather than as markup.
        static let symbols: [String: String] = [
            "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
            "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "ll": "≪", "gg": "≫",
            "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
            "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀", "exists": "∃",
            "sum": "Σ", "prod": "∏", "int": "∫", "oint": "∮", "partial": "∂", "nabla": "∇",
            "infty": "∞", "sqrtsign": "√", "angle": "∠", "perp": "⊥", "parallel": "∥",
            "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
            "Rightarrow": "⇒", "Leftarrow": "⇐", "iff": "⇔", "mapsto": "↦",
            "langle": "⟨", "rangle": "⟩", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖",
            "vert": "|", "Vert": "‖", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
            "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
            "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
            "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
            "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        ]
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
