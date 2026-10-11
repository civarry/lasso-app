import Foundation

// E. The runtime fallback. Knows nothing about providers or pricing: it asks for ranked candidates,
// builds providers from them, and records health.

/// Which model answered instead of the selected one. Delivered beside the answer, never inside it: the
/// stream is the model's output, and callers use it as such (Chat splits reasoning from it, Grammar Fix
/// pastes it back as the corrected text).
struct FallbackNotice: Equatable, Sendable {
    var answeredBy: String
    var insteadOf: String
    var onDevice: Bool
    /// Why the selected model didn't answer: its own failure, never a candidate's.
    var reason: ModelFailure
    /// Set when the selected model hadn't failed but hadn't started answering either, and a free model
    /// racing it answered first: the wait, in seconds.
    var slowAfter: Int? = nil
    /// The selected model was skipped entirely: it missed often enough that requests are being routed
    /// around it for now (`PrimaryCircuit`).
    var routed = false

    /// Honest about the cause. A 404 is not an outage: the model name or base URL is wrong, or the
    /// provider withdrew the model, and calling that "temporarily unavailable" would send the user
    /// waiting for something that won't come back on its own. Nor is a slow model unavailable.
    var reasonText: String {
        if routed { return "\(insteadOf) isn't responding, so it's being skipped for now" }
        if slowAfter == 0 { return "\(insteadOf) has been slow lately, so a free model started with it" }
        if let slowAfter { return "\(insteadOf) hadn't started answering after \(slowAfter) s" }
        return reason == .modelGone
            ? "\(insteadOf) wasn't found (check the model name and base URL)"
            : "\(insteadOf) was temporarily unavailable"
    }

    var text: String {
        "Answered \(onDevice ? "on-device " : "")by \(answeredBy) because \(reasonText)"
    }
}

/// How far one request may fall back. Chat and the capture actions use `.full`; background work the
/// user never sees (the chat summarizer) uses `.none`, so it can't quietly send a conversation to a
/// provider the user didn't pick, or occupy the on-device model behind the user's back.
enum FallbackScope: Sendable, Equatable {
    /// Free models (when the pool is allowed), then on-device.
    case full
    /// No free models: on-device only, the rule from before the pool existed.
    case onDeviceOnly
    /// No retry at all: the selected model's error surfaces.
    case none
}

/// Streams a request and, if it fails before the first token, moves along: the selected model, then
/// compatible free models, then the on-device model, then the selected model's error. Never after a
/// token has streamed, which would splice two models into one answer, and never back to the cloud
/// once on-device.
///
/// A selected model that is merely slow is raced rather than abandoned: once `raceAfter` passes with no
/// token, the best free candidate starts alongside it and whichever answers first wins; the other is
/// cancelled. A model that is quietly thinking isn't cut off, it just has competition, and one that is
/// a moment from answering still wins. Racing only happens where the pool itself is allowed.
///
/// Everything it touches from outside comes in as a closure, so the loop runs in tests against fake
/// providers instead of only reading correctly.
@MainActor
final class FallbackDriver {
    static let maxPoolAttempts = 3
    /// Stop reaching for more cloud candidates once the fallback has been running this long; each one
    /// can take a full network timeout, and on-device answers in seconds. Counted from the selected
    /// model's failure, not the start of the request: a primary that times out after a minute has
    /// already spent more than this, and must still get a candidate.
    static let poolDeadline: TimeInterval = 30
    /// A candidate's request timeout. The selected model gets the providers' usual 60 s; a stand-in that
    /// hasn't said a word in 20 s is less use than the next one.
    static let candidateTimeout: TimeInterval = 20

    var health: ModelHealth
    /// Whether the pool may be used for this primary (`FallbackPolicy.poolAllowed`). Asked again before
    /// every pool attempt, so turning on local-only mid-request stops the next cloud attempt.
    var poolAllowed: (IntelligenceProvider) -> Bool
    var candidates: (FallbackNeeds, Set<ModelRef>) -> [FallbackCandidate]
    /// Re-check the providers for next time. Never awaited: a request with nothing left to try goes
    /// on-device now rather than waiting on a round of `/models` calls.
    var refreshInBackground: () -> Void
    var makeProvider: (FallbackCandidate) -> IntelligenceProvider
    /// The on-device model, when it can serve this request (it is asked with the request's needs: a
    /// conversation past its window is no use to it).
    var lastResort: (IntelligenceProvider, FallbackNeeds) async -> IntelligenceProvider?
    var now: () -> Date
    /// Seconds the selected model may go without a token before a free model races it; nil = never.
    /// Read once per request (the user's Settings choice).
    var raceAfter: () -> TimeInterval?
    /// How the race timer waits. Injected so tests can drive it without real delays.
    var sleep: @Sendable (TimeInterval) async -> Void

    init(health: ModelHealth,
         poolAllowed: @escaping (IntelligenceProvider) -> Bool,
         candidates: @escaping (FallbackNeeds, Set<ModelRef>) -> [FallbackCandidate],
         refreshInBackground: @escaping () -> Void,
         makeProvider: @escaping (FallbackCandidate) -> IntelligenceProvider,
         lastResort: @escaping (IntelligenceProvider, FallbackNeeds) async -> IntelligenceProvider?,
         now: @escaping () -> Date = Date.init,
         raceAfter: @escaping () -> TimeInterval? = { nil },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.health = health
        self.poolAllowed = poolAllowed
        self.candidates = candidates
        self.refreshInBackground = refreshInBackground
        self.makeProvider = makeProvider
        self.lastResort = lastResort
        self.now = now
        self.raceAfter = raceAfter
        self.sleep = sleep
    }

    private enum Role { case selected, candidate, onDevice }

    private struct Attempt {
        let provider: IntelligenceProvider
        let ref: ModelRef?
        let role: Role
        /// The pool entry a candidate came from, so a request that ends on it can say where to route
        /// next time (`PrimaryCircuit`).
        let candidate: FallbackCandidate?
        let task: Task<Void, Never>
    }

    private enum Event {
        case delta(Int, String)
        case finished(Int)
        case failed(Int, Error)
        case slow
    }

    /// - Parameters:
    ///   - primaryRef: the registry model behind `primary`, so its own failure benches it too; nil for
    ///     Anthropic, a hand-typed model, or a local engine.
    ///   - scope: how far this request may fall back (`FallbackScope`).
    ///   - onAttempt: called just before each provider is tried, with whether it is the selected model.
    ///     The request is about to leave for that provider whether or not it answers (the privacy badge).
    ///     Only the selected model's attempt may be attributed: until something answers, the footer
    ///     should name the model the user picked, not whatever the previous request used. A candidate's
    ///     or the on-device model's attempt is never attributed.
    ///   - onServe: called once, at the first token, with the provider that is answering (attribution).
    ///     A candidate that fails is never named. The user's selected model is never written: a
    ///     fallback lasts for this one request.
    ///   - onFallback: called once, when a model other than the selected one starts answering.
    ///   - routedFrom: the name of the model this request is standing in for, when the user's selected
    ///     model is being routed around (`PrimaryCircuit`); `primary` is then the stand-in. Only changes
    ///     what the notice says: the loop treats the stand-in as the model to try first.
    ///   - exclude: models that must not be tried as candidates (the routed-around model itself).
    ///   - onOutcome: called once when the request ends, with who answered, so the caller can remember
    ///     a model that keeps missing.
    ///   - open: the request, applied unchanged to whichever provider is serving.
    func stream(primary: IntelligenceProvider, primaryRef: ModelRef?, needs: FallbackNeeds, label: String,
                scope: FallbackScope = .full,
                routedFrom: String? = nil,
                exclude: Set<ModelRef> = [],
                onOutcome: @escaping (RequestOutcome, String?) -> Void = { _, _ in },
                onAttempt: @escaping (_ provider: IntelligenceProvider, _ isSelected: Bool) -> Void = { _, _ in },
                onServe: @escaping (IntelligenceProvider) -> Void,
                onFallback: @escaping (FallbackNotice) -> Void = { _ in },
                open: @escaping @Sendable (IntelligenceProvider) -> AsyncThrowingStream<String, Error>)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                // Every running attempt reports into one event stream; this loop is the only place that
                // decides anything, so there's no shared state between attempts to race on.
                let (events, sink) = AsyncStream<Event>.makeStream()
                var attempts: [Int: Attempt] = [:]
                var nextID = 0
                var winner: Int?
                var winnerRole: Role?
                var winnerCandidate: FallbackCandidate?
                var winnerName: String?
                var tried: Set<ModelRef> = exclude.union(primaryRef.map { [$0] } ?? [])
                var poolAttempts = 0
                var refreshScheduled = false
                var onLastResort = false
                var primaryError: Error?
                var primaryFailure = ModelFailure.other
                var poolStarted: Date?
                var raceTimer: Task<Void, Never>?
                var raced: Int?
                var ended = false

                @MainActor func poolAllowedNow() -> Bool {
                    guard scope == .full else { return false }
                    return self.poolAllowed(primary)
                }
                /// Once per request, whichever reason comes first; the refresher rate-limits across requests.
                @MainActor func scheduleRefresh() {
                    guard !refreshScheduled else { return }
                    refreshScheduled = true
                    self.refreshInBackground()
                }
                @MainActor func launch(_ provider: IntelligenceProvider, ref: ModelRef?, role: Role,
                                       candidate: FallbackCandidate? = nil) {
                    nextID += 1
                    let id = nextID
                    onAttempt(provider, role == .selected)
                    let run = Task { @MainActor in
                        do {
                            for try await delta in open(provider) { sink.yield(.delta(id, delta)) }
                            sink.yield(.finished(id))
                        } catch {
                            sink.yield(.failed(id, error))
                        }
                    }
                    attempts[id] = Attempt(provider: provider, ref: ref, role: role, candidate: candidate, task: run)
                }
                /// Stop everything but `keep`. A cancelled attempt's late events are ignored (it's no
                /// longer in `attempts`), and nothing is recorded for it: losing a race, or being
                /// abandoned by the user, says nothing about a model's health.
                @MainActor func cancelAll(except keep: Int?) {
                    for (id, attempt) in attempts where id != keep { attempt.task.cancel() }
                    attempts = attempts.filter { $0.key == keep }
                    raceTimer?.cancel()
                }
                @MainActor func end(_ error: Error?) {
                    guard !ended else { return }
                    ended = true
                    let outcome: RequestOutcome
                    switch winnerRole {
                    case .selected: outcome = .selectedAnswered
                    case .candidate: outcome = .substituteAnswered(winnerCandidate, selectedFailed: primaryError != nil)
                    case .onDevice: outcome = .substituteAnswered(nil, selectedFailed: primaryError != nil)
                    case nil:
                        // Nothing answered: only a fallback-worthy failure of the selected model says
                        // anything about it. A bad key, a bad request or a cancelled reply says nothing.
                        outcome = (primaryError != nil && !Task.isCancelled) ? .selectedMissed : .notCounted
                    }
                    onOutcome(outcome, winnerName)
                    cancelAll(except: nil)
                    sink.finish()
                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                }
                @MainActor func notice(for attempt: Attempt) -> FallbackNotice {
                    // While routing around a model, every answer stands in for *it*, not for the
                    // stand-in the request happened to start with.
                    if let routedFrom, attempt.role == .selected {
                        return FallbackNotice(answeredBy: attempt.provider.name, insteadOf: routedFrom,
                                              onDevice: false, reason: .other, routed: true)
                    }
                    return FallbackNotice(answeredBy: attempt.provider.name, insteadOf: routedFrom ?? primary.name,
                                          onDevice: attempt.role == .onDevice, reason: primaryFailure,
                                          slowAfter: primaryError == nil ? raced : nil, routed: routedFrom != nil)
                }
                /// Start the best candidate still untried, within the attempt cap and the pool budget.
                @MainActor func launchCandidate() -> Bool {
                    guard poolAllowedNow(), !onLastResort, poolAttempts < Self.maxPoolAttempts,
                          let poolStarted, self.now().timeIntervalSince(poolStarted) < Self.poolDeadline
                    else { return false }
                    // Nothing left to try: the registry may be out of date. Check for next time.
                    guard let next = self.candidates(needs, tried).first else { scheduleRefresh(); return false }
                    poolAttempts += 1
                    tried.insert(next.ref)
                    let provider = self.makeProvider(next)
                    Log.intelligence.notice("\(label, privacy: .public) · trying free model \(provider.name, privacy: .public) (\(next.source.rawValue, privacy: .public))")
                    launch(provider, ref: next.ref, role: .candidate, candidate: next)
                    return true
                }
                /// Nothing is running and nothing has answered: the next candidate, else on-device.
                @MainActor func moveOn() async -> Bool {
                    if launchCandidate() { return true }
                    // Several free candidates failed: re-check in the background for next time.
                    if poolAttempts >= Self.maxPoolAttempts { scheduleRefresh() }
                    // The on-device model has no tool loop. A turn that depends on one (the user asked
                    // for a search) would get an answer from stale knowledge dressed as a search
                    // result, so it gets the selected model's error instead.
                    guard !onLastResort, needs.tools != .required,
                          let fallback = await self.lastResort(primary, needs), !Task.isCancelled else { return false }
                    onLastResort = true
                    launch(fallback, ref: nil, role: .onDevice)
                    return true
                }
                /// Something that hasn't answered failed. Returns false when the request is over.
                @MainActor func handleFailure(of id: Int, _ attempt: Attempt, _ error: Error) async -> Bool {
                    let failure = ModelFailure.classify(error)
                    // The selected model is usually paid, with a rate limit of its own: its 429 is not
                    // evidence that the connection's shared free cap is spent.
                    if let ref = attempt.ref {
                        // Only the user's own model is exempt from its connection's shared cap. While
                        // routing around it, the "selected" attempt is a free stand-in like any other.
                        let isUsersOwnModel = attempt.role == .selected && routedFrom == nil
                        self.health.record(failure, for: ref, countsTowardSharedCap: !isUsersOwnModel)
                    }
                    if failure == .cancelled { end(error); return false }
                    if attempt.role == .selected {
                        guard scope != .none else { end(error); return false }
                        // Leaving the user's model at all. With the pool off this is exactly the old
                        // on-device rule; with it on, a withdrawn model also counts. A bad key or a bad
                        // request ends the request even mid-race: a racer would only hide it.
                        let leave = poolAllowedNow() ? failure.triggersFallback
                                                     : IntelligenceCoordinator.isTransient(error)
                        guard leave else { end(error); return false }
                        primaryError = error
                        primaryFailure = failure
                        if poolStarted == nil { poolStarted = self.now() }
                    }
                    Log.intelligence.notice("\(label, privacy: .public) · \(attempt.provider.name, privacy: .public) failed before answering (\(error.localizedDescription, privacy: .public))")
                    if attempts.isEmpty {
                        guard await moveOn() else {
                            // Report the user's own model's failure: that is the one they chose and can fix.
                            end(primaryError ?? error)
                            return false
                        }
                    } else if attempt.role == .candidate {
                        // A racer failed while the selected model is still working: keep one racing.
                        _ = launchCandidate()
                    }
                    return true
                }

                launch(primary, ref: primaryRef, role: .selected)
                // Asked only where a race could actually happen: `raceAfter` reads the circuit, and a
                // background request (the summarizer, Identify) must not arm the selected model's second
                // chance on its behalf.
                let raceWait = (scope == .full && poolAllowedNow()) ? self.raceAfter() : nil
                // 0 means "start the stand-in with this request": the selected model has been losing on
                // time lately, so it races from the first moment rather than after another wait.
                if let wait = raceWait, wait >= 0 {
                    let sleep = self.sleep
                    raceTimer = Task { @MainActor in
                        if wait > 0 { await sleep(wait) }
                        if !Task.isCancelled { sink.yield(.slow) }
                    }
                }

                for await event in events {
                    // The caller went away (the user stopped the reply, closed the card): stop
                    // everything, record nothing.
                    if Task.isCancelled { break }
                    switch event {
                    case .slow:
                        guard winner == nil, primaryError == nil, raced == nil,
                              attempts.values.contains(where: { $0.role == .selected }) else { continue }
                        raced = Int((raceWait ?? 0).rounded())
                        if poolStarted == nil { poolStarted = self.now() }
                        Log.intelligence.notice("\(label, privacy: .public) · \(primary.name, privacy: .public) hasn't answered after \(raced ?? 0, privacy: .public) s; racing a free model")
                        _ = launchCandidate()

                    case .delta(let id, let delta):
                        guard let attempt = attempts[id] else { continue }
                        if winner == nil {
                            // First token anywhere decides the request. Attribution and the notice belong
                            // to the model that actually answers, so they wait for it.
                            winner = id
                            winnerRole = attempt.role
                            winnerCandidate = attempt.candidate
                            winnerName = attempt.provider.name
                            cancelAll(except: id)
                            onServe(attempt.provider)
                            if attempt.role != .selected || routedFrom != nil { onFallback(notice(for: attempt)) }
                        }
                        if id == winner { continuation.yield(delta) }

                    case .finished(let id):
                        guard let attempt = attempts[id] else { continue }
                        if id != winner, attempt.role == .candidate {
                            // A stand-in that says nothing is no answer.
                            attempts[id] = nil
                            if await handleFailure(of: id, attempt, IntelligenceError.emptyResponse(attempt.provider.name)) { continue }
                            break
                        }
                        // The selected and on-device models keep their old behaviour: an empty reply is
                        // theirs to give.
                        if winner == nil {
                            winner = id
                            winnerRole = attempt.role
                            winnerCandidate = attempt.candidate
                            winnerName = attempt.provider.name
                            cancelAll(except: id)
                            onServe(attempt.provider)
                        }
                        if let ref = attempt.ref { self.health.recordSuccess(ref) }
                        end(nil)

                    case .failed(let id, let error):
                        guard let attempt = attempts[id] else { continue }
                        attempts[id] = nil
                        // Once a model has answered, never splice another in: its error surfaces.
                        if id == winner { end(error); break }
                        if Task.isCancelled { break }
                        if await handleFailure(of: id, attempt, error) { continue }
                    }
                    if ended { break }
                }
                // Cancelled, or the event stream ended: nothing left running either way.
                end(nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
