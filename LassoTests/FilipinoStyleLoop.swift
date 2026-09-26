import Testing
import Foundation
@testable import Lasso

/// Feedback loop for the Filipino style rules: translate a mixed-register corpus with the configured
/// Groq model, score it mechanically, and have Gemini (a different model family) judge naturalness.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_FIL_LOOP"] == "1"))
@MainActor
struct FilipinoStyleLoop {
    struct Item {
        let id: Int; let register: String; let text: String; let keepEnglish: [String]
        var heldOut = false
    }

    static let corpus: [Item] = [
        .init(id: 1, register: "formal notice", text: "Dear Valued Subscriber, You may be experiencing connectivity issues due to a network problem. We assure you that our technical team is working to restore your connection. If you have any open case that is related to this specific issue, it will be automatically resolved once the restoration is complete.", keepEnglish: ["technical team"]),
        .init(id: 2, register: "security alert", text: "We detected an unusual sign-in attempt on your account. If this was you, you can ignore this message. Otherwise, please reset your password immediately.", keepEnglish: ["account", "password"]),
        .init(id: 3, register: "delivery update", text: "Your order has been shipped and is expected to arrive within 3–5 business days. You can track your package using the link below.", keepEnglish: ["order", "link"]),
        .init(id: 4, register: "UI label", text: "Save changes", keepEnglish: []),
        .init(id: 5, register: "UI dialog", text: "Are you sure you want to delete this file? This action cannot be undone.", keepEnglish: ["file"]),
        .init(id: 6, register: "error message", text: "Something went wrong. Please check your internet connection and try again.", keepEnglish: ["internet"]),
        .init(id: 7, register: "casual chat", text: "lol that meeting could've been an email. wanna grab lunch later?", keepEnglish: ["meeting", "email"]),
        .init(id: 8, register: "social post", text: "tldr: been working on a personal game project, no review yet so take it with a grain of salt.", keepEnglish: ["game", "project"]),
        .init(id: 9, register: "news", text: "The government announced a new policy to reduce traffic congestion in Metro Manila starting next month.", keepEnglish: ["Metro Manila"]),
        .init(id: 10, register: "medicine label", text: "Take one tablet twice a day after meals. Do not exceed the recommended dose.", keepEnglish: []),
        .init(id: 11, register: "marketing", text: "Upgrade to Premium and enjoy unlimited access to all features. Cancel anytime.", keepEnglish: ["Premium"]),
        .init(id: 12, register: "work email", text: "Hi team, just a reminder that the deadline for the quarterly report is on Friday. Please send your updates by Thursday EOD.", keepEnglish: ["deadline", "report", "EOD"]),
        .init(id: 13, register: "instructions", text: "To reset your device, press and hold the power button for 10 seconds until the logo appears.", keepEnglish: ["power button", "logo"]),
        .init(id: 14, register: "customer service", text: "We're sorry for the delay. Your refund has been processed and should reflect in your account within 7 banking days.", keepEnglish: ["refund", "account"]),
        .init(id: 15, register: "idiom", text: "Don't put all your eggs in one basket.", keepEnglish: []),
        .init(id: 16, register: "tech news", text: "The new update improves battery life and fixes several bugs reported by users.", keepEnglish: ["update", "battery", "bug"]),
        // Formerly held out; moved to tuning after the prompt's examples leaked some of their phrases.
        .init(id: 17, register: "school announcement", text: "Classes are suspended tomorrow due to the typhoon. Students are advised to stay home and check the school's Facebook page for updates.", keepEnglish: ["Facebook"]),
        .init(id: 18, register: "government advisory", text: "Applicants must submit a valid ID and proof of billing. Incomplete requirements will not be processed.", keepEnglish: ["ID"]),
        .init(id: 19, register: "weather alert", text: "Heavy rainfall is expected this afternoon. Avoid unnecessary travel and stay updated through official channels.", keepEnglish: []),
        .init(id: 20, register: "app permission", text: "Allow this app to access your location while you're using it? You can change this anytime in Settings.", keepEnglish: ["app", "Settings"]),
        .init(id: 21, register: "promo", text: "Flash sale! Get 50% off on all items this weekend only. Use code SAVE50 at checkout.", keepEnglish: ["Flash sale", "SAVE50", "checkout"]),
        .init(id: 22, register: "recipe step", text: "Heat the oil in a pan, then sauté the garlic and onions until fragrant.", keepEnglish: []),
        // Held out: none of these phrases may appear in the prompt. They only check the rules generalise.
        .init(id: 23, register: "bank SMS", text: "Your OTP is 482913. Do not share this code with anyone, including bank staff.", keepEnglish: ["OTP", "482913"], heldOut: true),
        .init(id: 24, register: "ride-hailing", text: "Your driver is arriving in 3 minutes. Please wait at the pickup point.", keepEnglish: ["driver"], heldOut: true),
        .init(id: 25, register: "HR memo", text: "All employees are required to attend the mandatory safety training on Monday at 9 AM.", keepEnglish: ["training"], heldOut: true),
        .init(id: 26, register: "product review", text: "Honestly not worth the price. The battery drains fast and customer support never replied.", keepEnglish: ["customer support"], heldOut: true),
        .init(id: 27, register: "app onboarding", text: "Welcome! Let's set up your profile so we can personalize your experience.", keepEnglish: ["profile"], heldOut: true),
        .init(id: 28, register: "idiom", text: "It's not rocket science, just follow the steps and you'll be fine.", keepEnglish: [], heldOut: true),
    ]

    /// Words the loop has found unnatural in modern Filipino (grown as the judge flags them).
    static let deepWords = ["tagasubskribe", "pinahahalagahang", "koponan", "pagpapanumbalik", "kagawaran",
                            "tagapayo", "kagyat", "hanapbuhay", "sulatroniko", "nais"]

    func provider(_ url: String, _ keyAccount: String, _ model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(baseURL: URL(string: url)!, apiKey: Keychain.get(keyAccount) ?? "", model: model, displayName: model)
    }

    func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> String {
        var t = ""; for try await d in s { t += d }; return t
    }

    /// `LASSO_FIL_MODELS`: comma-separated "connection|model" pairs, e.g.
    /// "Groq|openai/gpt-oss-120b,OpenRouter|nvidia/nemotron-3-ultra-550b-a55b:free,Gemini|gemini-flash-latest".
    /// Texts go in groups of 4 per request (4x fewer requests; fits free-tier daily caps).
    @Test func loop() async throws {
        let env = ProcessInfo.processInfo.environment
        let label = env["LASSO_FIL_LABEL"] ?? "run"
        let specs = (env["LASSO_FIL_MODELS"] ?? "Groq|openai/gpt-oss-120b").split(separator: ",").map {
            let parts = $0.split(separator: "|", maxSplits: 1).map(String.init)
            return (connection: parts[0], model: parts[1])
        }
        let registry = KeysRegistry.load()
        let gemini = registry.entries.first { $0.kind == .gemini }

        var results: [String: [Int: String]] = [:]   // model → id → translation
        for spec in specs {
            let translator: IntelligenceProvider
            if spec.connection == "Gemini", let gemini {
                translator = GeminiProvider(apiKey: Keychain.get(gemini.keychainAccount) ?? "", model: spec.model, displayName: "Gemini")
            } else if let entry = registry.entries.first(where: { $0.name == spec.connection }) {
                translator = provider(entry.baseURL, entry.keychainAccount, spec.model)
            } else { print("[loop] no connection \(spec.connection)"); continue }

            var out: [Int: String] = [:]
            for group in stride(from: 0, to: Self.corpus.count, by: 4).map({ Array(Self.corpus[$0..<min($0 + 4, Self.corpus.count)]) }) {
                let blocks = group.map { TextBlock(id: UUID(), lineIDs: [], text: $0.text, frame: .zero, language: .init(identifier: "en")) }
                let got = Box()
                for attempt in 1...4 {
                    do {
                        try await LLMTranslator { m, _ in translator.respond(messages: m) }
                            .translate(blocks, targetName: "Filipino", targetCode: "fil", chunkLimit: 6000) { await got.add($0, $1) }
                        break
                    } catch {
                        let text = "\(error)"
                        print("[loop] \(spec.model) group@\(group[0].id) attempt \(attempt): \(text.prefix(140))")
                        if text.contains("per day") || text.contains("TPD") || text.contains("RPD") { break }
                        try await Task.sleep(for: .seconds(15))
                    }
                }
                let v = await got.v
                for (item, block) in zip(group, blocks) { out[item.id] = v[block.id] ?? "<missing>" }
            }
            results[spec.model] = out
        }

        // Side by side, with mechanical flags, for review.
        var totals: [String: (deep: Int, ay: Int, mixed: Int, lost: Int, missing: Int)] = [:]
        for item in Self.corpus {
            print("[item] \(item.id)\(item.heldOut ? " HELD-OUT" : "") [\(item.register)] EN: \(item.text)")
            for spec in specs {
                guard let text = results[spec.model]?[item.id] else { continue }
                let t = " " + text.lowercased() + " "
                let deep = Self.deepWords.filter { t.contains($0) }
                let ay = t.components(separatedBy: " ay ").count - 1
                let informal = [" ka ", " mo ", " mo.", " mo,", " mo?", " iyong ", " ikaw "].contains { t.contains($0) }
                let formal = [" kayo", " inyong ", " ninyo", " inyo "].contains { t.contains($0) }
                let lost = item.keepEnglish.filter { !t.contains($0.lowercased()) }
                var tot = totals[spec.model] ?? (0, 0, 0, 0, 0)
                tot.deep += deep.count; tot.ay += ay; tot.mixed += (informal && formal) ? 1 : 0; tot.lost += lost.count
                tot.missing += text == "<missing>" ? 1 : 0
                totals[spec.model] = tot
                let flags = (deep.isEmpty ? "" : " ⟨deep \(deep)⟩") + (ay > 0 ? " ⟨ay×\(ay)⟩" : "")
                    + (informal && formal ? " ⟨ka/kayo⟩" : "") + (lost.isEmpty ? "" : " ⟨lost \(lost)⟩")
                print("[fil] \(spec.model.split(separator: "/").last ?? ""): \(text)\(flags)")
            }
        }
        for spec in specs {
            if let t = totals[spec.model] {
                print("[summary] \(label) \(spec.model) deep=\(t.deep) ay=\(t.ay) mixed=\(t.mixed) englishLost=\(t.lost) missing=\(t.missing)")
            }
        }
    }

    /// Every top-level {...} in `text`, wherever the judge put it (one per line, all on one line,
    /// or wrapped in commentary).
    static func jsonObjects(in text: String) -> [[String: Any]?] {
        var out: [[String: Any]?] = [], depth = 0, start: String.Index?, inString = false, escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { if depth > 0 { inString = true } }
            else if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let st = start {
                    out.append(try? JSONSerialization.jsonObject(with: Data(text[st...i].utf8)) as? [String: Any])
                }
            }
            i = text.index(after: i)
        }
        return out
    }

    func json(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self).dropFirst().dropLast().description
    }
}
private actor Box { var v: [UUID: String] = [:]; func add(_ i: UUID, _ s: String) { v[i] = s } }
