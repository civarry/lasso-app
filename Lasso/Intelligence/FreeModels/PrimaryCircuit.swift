import Foundation

// F (routing memory). The fallback driver handles one request; this remembers across requests. A
// selected model that keeps missing (failing, or losing the race to a free model) shouldn't make every
// message wait out the race timer before something useful happens. After `threshold` misses in a row it
// is routed around: requests go straight to the model that last answered instead, for a cooldown that
// doubles while the selected model keeps missing. The user's selection never changes; when the cooldown
// ends the selected model gets the next request again (raced as usual), and one answer from it closes
// the circuit.

/// How a request ended, from the selected model's point of view. Reported by `FallbackDriver`.
enum RequestOutcome: Equatable, Sendable {
    /// The selected model answered (or, for a routed request, the stand-in it was routed to).
    case selectedAnswered
    /// Something else answered: a free candidate, or on-device (nil). `selectedFailed` separates a
    /// selected model that broke from one that was merely beaten to the first token: being slow is not
    /// grounds for setting a model aside, being down is.
    case substituteAnswered(FallbackCandidate?, selectedFailed: Bool)
    /// The selected model failed in a way worth falling back for, and nothing answered.
    case selectedMissed
    /// Says nothing about the selected model's health: a bad key or request the user must fix, a
    /// cancelled request, or a request whose scope doesn't use the pool.
    case notCounted
}

/// What to do about a selected model that keeps missing.
enum CircuitMode: Equatable, Sendable {
    /// It is failing: skip it entirely and send requests to the stand-in.
    case routeAround
    /// It works, it is just slow: keep sending to it, but start the stand-in at the same moment instead
    /// of waiting out the Slow model timer. The user's own model still wins whenever it answers first.
    case raceImmediately
}

/// The circuit is open. What the Chat header shows.
struct RoutedAround: Equatable, Sendable {
    var mode: CircuitMode
    var primaryKey: String
    var primaryName: String
    /// The model requests go to instead; nil = the on-device model.
    var substitute: FallbackCandidate?
    var substituteName: String
    /// When the selected model gets a request again.
    var retryAt: Date
}

@MainActor
final class PrimaryCircuit {
    /// Misses in a row before routing around. One can be a blip; two within a few minutes is usually an
    /// outage or a rate limit that won't clear soon (the user's choice, 2026-09-20).
    static let threshold = 2
    /// Misses further apart than this aren't "in a row".
    static let missWindow: TimeInterval = 10 * 60
    static let firstCooldown: TimeInterval = 5 * 60
    static let maxCooldown: TimeInterval = 30 * 60

    private let now: () -> Date
    private var key: String?
    private var misses: [(at: Date, failed: Bool)] = []
    private var lastSubstitute: (candidate: FallbackCandidate?, name: String)?
    private var cooldown = firstCooldown
    private var probing = false
    private(set) var routed: RoutedAround?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Where this request should go: the stand-in while the circuit is open in `routeAround`, nil to use
    /// the selected model (closed, racing instead, or the cooldown is over and it gets another chance).
    func route(primaryKey: String) -> RoutedAround? {
        guard let open = live(primaryKey), open.mode == .routeAround else { return nil }
        return open
    }

    /// The selected model is slow rather than broken: it still gets the request, with a stand-in started
    /// beside it immediately.
    func racesImmediately(primaryKey: String) -> Bool {
        live(primaryKey)?.mode == .raceImmediately
    }

    /// The open circuit for this model, or nil once the cooldown has passed (which arms the next request
    /// as its second chance).
    private func live(_ primaryKey: String) -> RoutedAround? {
        guard key == primaryKey, let routed else { return nil }
        if now() < routed.retryAt { return routed }
        probing = true
        return nil
    }

    /// Record how a request ended. `routed` = it went to the stand-in without trying the selected model.
    func record(primaryKey: String, primaryName: String, outcome: RequestOutcome, answeredBy: String?,
                routed wasRouted: Bool) {
        if key != primaryKey { reset(); key = primaryKey }
        if wasRouted {
            // The selected model wasn't asked, so this is news about the stand-in only. If a different
            // model had to answer, route to that one from now on.
            if case .substituteAnswered(let candidate, _) = outcome, let answeredBy {
                routed?.substitute = candidate
                routed?.substituteName = answeredBy
            }
            return
        }
        switch outcome {
        case .selectedAnswered:
            let keep = key
            reset()
            key = keep
        case .substituteAnswered(let candidate, let selectedFailed):
            if let answeredBy { lastSubstitute = (candidate, answeredBy) }
            miss(primaryName: primaryName, failed: selectedFailed)
        case .selectedMissed:
            miss(primaryName: primaryName, failed: true)
        case .notCounted:
            break
        }
    }

    /// The user asked to try their model again: the next request goes to it.
    func retryNow() {
        routed?.retryAt = now()
    }

    func reset() {
        key = nil
        misses = []
        lastSubstitute = nil
        cooldown = Self.firstCooldown
        probing = false
        routed = nil
    }

    private func miss(primaryName: String, failed: Bool) {
        let time = now()
        if probing, var open = routed {
            // Its second chance missed too: skip it for longer.
            probing = false
            cooldown = min(cooldown * 2, Self.maxCooldown)
            if let substitute = lastSubstitute {
                open.substitute = substitute.candidate
                open.substituteName = substitute.name
            }
            if failed { open.mode = .routeAround }
            open.retryAt = time + cooldown
            routed = open
            return
        }
        misses = misses.filter { time.timeIntervalSince($0.at) < Self.missWindow } + [(time, failed)]
        guard misses.count >= Self.threshold, let substitute = lastSubstitute, let key else { return }
        // A model that broke is skipped. One that merely lost the race is kept, and raced from the
        // first moment instead: the user keeps their own model whenever it is ready in time.
        let mode: CircuitMode = misses.contains { $0.failed } ? .routeAround : .raceImmediately
        misses = []
        routed = RoutedAround(mode: mode, primaryKey: key, primaryName: primaryName,
                              substitute: substitute.candidate, substituteName: substitute.name,
                              retryAt: time + cooldown)
    }
}
