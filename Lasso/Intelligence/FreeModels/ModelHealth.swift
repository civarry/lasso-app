import Foundation

// F (health). Availability, kept apart from free status on purpose: a rate-limited free model is still
// free, it just sits out for a while.

/// A registry model, addressed the way selection addresses it: the same model name under two
/// connections is two different models with separate limits.
struct ModelRef: Hashable, Sendable {
    var keyID: String
    var model: String
}

enum ModelFailure: Equatable, Sendable {
    case rateLimited      // 429
    case unavailable      // 5xx, overloaded, timed out
    case connectionDown   // the host can't be reached at all
    case modelGone        // 404, or OpenRouter's 400 "is not a valid model ID": withdrawn, renamed, or not available to this key
    case unauthorized     // 401 / 403
    case rejected         // 400 / 413 / 422: something about this request
    case cancelled
    case other

    /// Worth leaving the user's chosen model for: problems that a different model can get around. Not a
    /// bad key, an oversized or malformed request, or cancellation: those need the user, and a chain of
    /// fallbacks would only hide them.
    var triggersFallback: Bool {
        switch self {
        case .rateLimited, .unavailable, .connectionDown, .modelGone: true
        default: false
        }
    }

    /// Providers surface HTTP failures as `IntelligenceError.server("… HTTP 429 …")` and transport
    /// failures as `URLError`, so classify on both. The status code is authoritative when present.
    static func classify(_ error: Error) -> ModelFailure {
        if error is CancellationError { return .cancelled }
        // A candidate that ended without a word: nothing to show, so the next model gets a turn.
        if case IntelligenceError.emptyResponse = error { return .unavailable }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .unavailable
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .resourceUnavailable:
                return .connectionDown
            default: return .other
            }
        }
        let message = error.localizedDescription
        if let code = httpStatus(in: message) {
            switch code {
            case 429: return .rateLimited
            case 404: return .modelGone
            case 401, 403: return .unauthorized
            case 400 where message.lowercased().contains("is not a valid model id"):
                // OpenRouter answers a model id it doesn't serve with 400, not 404 (verified live:
                // "… lasso-live-test/does-not-exist:free is not a valid model ID"). It won't come back
                // on a timer, so it's missing like a 404, not a rejected request.
                return .modelGone
            case 413 where isPerMinuteLimit(message):
                // Groq answers a request over the free plan's tokens-per-minute budget with 413, not
                // 429 ("Request too large … on tokens per minute (TPM)"). It is a rate limit: the same
                // request fits another model, or this one a minute later.
                return .rateLimited
            case 400, 413, 422: return .rejected
            case 500...599: return .unavailable
            default: return .other
            }
        }
        let lower = message.lowercased()
        if lower.contains("rate limit") { return .rateLimited }
        if lower.contains("overloaded") || lower.contains("timed out") || lower.contains("timeout") {
            return .unavailable
        }
        return .other
    }

    private static func isPerMinuteLimit(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("per minute") || lower.contains("tpm")
    }

    private static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(5))
    }
}

enum ModelAvailability: Equatable, Sendable {
    case healthy
    case rateLimited          // cooldown, model or whole connection
    case unavailable          // cooldown after a server error or unreachable host
    case missing              // 404, until the next refresh
    case credentialsRejected  // 401/403 on the connection, until the next refresh
}

/// Which models and connections are benched right now. In memory only: a cooldown measured in minutes
/// means nothing after a relaunch, and a stale "down" mark would hide a recovered model.
@MainActor
final class ModelHealth {
    enum Cooldown {
        static let rateLimited: TimeInterval = 60
        static let unavailable: TimeInterval = 120
        static let connectionDown: TimeInterval = 120
        /// OpenRouter's free models share one daily cap per account, so after rate limits from two
        /// different models on a connection, the rest of that connection is almost certainly capped too.
        static let connectionRateLimited: TimeInterval = 600
        static let strikeWindow: TimeInterval = 120
    }

    /// `until == nil` means "until the next refresh".
    private struct Bench { var state: ModelAvailability; var until: Date? }

    private let now: () -> Date
    private var models: [ModelRef: Bench] = [:]
    private var connections: [String: Bench] = [:]
    private var rateLimitStrikes: [String: [ModelRef: Date]] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// - Parameter countsTowardSharedCap: whether a 429 here is evidence about the connection's shared
    ///   free cap. The user's own model is usually paid, with a limit of its own: its 429 plus one free
    ///   model's 429 is not two strikes against the free cap, and mustn't bench the whole connection.
    func record(_ failure: ModelFailure, for ref: ModelRef, countsTowardSharedCap: Bool = true) {
        let time = now()
        switch failure {
        case .rateLimited:
            models[ref] = Bench(state: .rateLimited, until: time + Cooldown.rateLimited)
            guard countsTowardSharedCap else { return }
            var strikes = (rateLimitStrikes[ref.keyID] ?? [:])
                .filter { time.timeIntervalSince($0.value) < Cooldown.strikeWindow }
            strikes[ref] = time
            rateLimitStrikes[ref.keyID] = strikes
            if strikes.count >= 2 {
                connections[ref.keyID] = Bench(state: .rateLimited, until: time + Cooldown.connectionRateLimited)
            }
        case .unavailable:
            models[ref] = Bench(state: .unavailable, until: time + Cooldown.unavailable)
        case .connectionDown:
            connections[ref.keyID] = Bench(state: .unavailable, until: time + Cooldown.connectionDown)
        case .modelGone:
            models[ref] = Bench(state: .missing, until: nil)
        case .unauthorized:
            connections[ref.keyID] = Bench(state: .credentialsRejected, until: nil)
        case .rejected:
            // A 400 is usually about this one request, but one that isn't recognizably a missing model
            // could still be a dead one, so bench on a timer rather than until refresh: long enough to
            // stop re-trying it on every request. (OpenRouter's "not a valid model ID" is `.modelGone`.)
            models[ref] = Bench(state: .unavailable, until: now() + Cooldown.unavailable)
        case .cancelled, .other:
            break
        }
    }

    func recordSuccess(_ ref: ModelRef) {
        models[ref] = nil
        rateLimitStrikes[ref.keyID]?[ref] = nil
    }

    func availability(of ref: ModelRef) -> ModelAvailability {
        let time = now()
        func active(_ bench: Bench?) -> ModelAvailability? {
            guard let bench else { return nil }
            if let until = bench.until, until <= time { return nil }
            return bench.state
        }
        return active(models[ref]) ?? active(connections[ref.keyID]) ?? .healthy
    }

    func isBenched(_ ref: ModelRef) -> Bool { availability(of: ref) != .healthy }

    /// A fresh model list is fresh evidence: withdrawn models are gone from it, re-added ones are back,
    /// and a key the user fixed gets another chance. Timed cooldowns keep running.
    func clearRefreshMarks() {
        models = models.filter { $0.value.until != nil }
        connections = connections.filter { $0.value.until != nil }
    }
}
