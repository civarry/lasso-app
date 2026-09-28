import Foundation

// F (refresh). Keeps the registry's model lists, and so the free pool, current outside Settings.
// Settings re-discovers on open, on add/edit, and from the Refresh buttons; this covers the rest:
// launch with a stale list, a request that finds nothing to fall back to, and a round of failures.

/// Concurrent callers share one refresh. The in-flight task is stored before the first suspension, and
/// everything here is main-actor isolated, so a caller arriving mid-refresh always finds it rather than
/// starting its own.
@MainActor
final class FreeModelRefresher {
    typealias Discover = @Sendable (RegisteredKey, String) async -> [RegistryModel]?

    static let staleAfter: TimeInterval = 24 * 60 * 60
    /// Automatic refreshes start at most this often, so a provider outage or a connection whose list
    /// keeps failing doesn't turn every fallback into a round of `/models` calls.
    static let minimumInterval: TimeInterval = 10 * 60

    private let store: UserDefaults
    private let discover: Discover
    private let keyValue: (RegisteredKey) -> String
    private let now: () -> Date
    private let onRefreshed: () -> Void
    private var inFlight: Task<Void, Never>?
    private(set) var lastAttempt: Date?

    init(store: UserDefaults = .standard,
         discover: @escaping Discover = { await KeysRegistry.discoverModels(for: $0, apiKey: $1) },
         keyValue: @escaping (RegisteredKey) -> String = { Keychain.get($0.keychainAccount) ?? "" },
         now: @escaping () -> Date = Date.init,
         onRefreshed: @escaping () -> Void = {}) {
        self.store = store
        self.discover = discover
        self.keyValue = keyValue
        self.now = now
        self.onRefreshed = onRefreshed
    }

    /// Some switched-on connection's list is older than a day, or was never fetched.
    var isStale: Bool {
        KeysRegistry.load(from: store).entries.filter(\.enabled).contains { entry in
            guard let checked = entry.modelsCheckedAt else { return true }
            return now().timeIntervalSince(checked) > Self.staleAfter
        }
    }

    /// An automatic refresh, skipped when one started within `minimumInterval`. Returns whether the
    /// registry was re-checked (joining one already in flight counts).
    @discardableResult
    func refreshIfDue() async -> Bool {
        if let inFlight { await inFlight.value; return true }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < Self.minimumInterval { return false }
        await refresh()
        return true
    }

    /// Refresh now, or join the one in flight.
    func refresh() async {
        if let inFlight { await inFlight.value; return }
        lastAttempt = now()
        let task = Task { @MainActor in
            await self.performRefresh()
            self.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Reconcile with what the providers serve now. A connection's model list is replaced, not merged,
    /// so a model that stopped being free (or stopped existing) leaves the pool instead of lingering as
    /// "once free". Everything the user owns on the connection (name, URL, Free tier) is untouched.
    private func performRefresh() async {
        let snapshot = KeysRegistry.load(from: store)
        // A switched-off connection is left alone: switching a provider off means Lasso stops
        // contacting it, not just that its models are hidden.
        let jobs = snapshot.entries.filter(\.enabled).map { ($0, keyValue($0)) }
        let discover = self.discover
        let results = await withTaskGroup(of: (RegisteredKey, String, [RegistryModel]?).self) { group in
            for (entry, key) in jobs { group.addTask { (entry, key, await discover(entry, key)) } }
            var collected: [String: (RegisteredKey, String, [RegistryModel]?)] = [:]
            for await (entry, key, models) in group { collected[entry.id] = (entry, key, models) }
            return collected
        }
        // Re-read after the network: Settings may have saved while we waited. Only write back to a
        // connection that still exists, still points where it did, and still uses the key the list was
        // fetched with (a different key can see different models, and a Groq or Google key on another
        // plan sees the same ids at a different price), and never replace a good list with a failed fetch.
        var current = KeysRegistry.load(from: store)
        let time = now()
        for index in current.entries.indices {
            let entry = current.entries[index]
            guard let (asked, askedKey, models) = results[entry.id], let models,
                  asked.baseURL == entry.baseURL, asked.kind == entry.kind,
                  keyValue(entry) == askedKey else { continue }
            current.entries[index].models = models
            current.entries[index].modelsCheckedAt = time
        }
        current.save(to: store)
        onRefreshed()
    }
}
