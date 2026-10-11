import Foundation

/// On-device cache of web-search results keyed by normalized query, so re-identifying the same thing
/// costs zero API quota. 7-day TTL; expired entries are pruned on write. Stored as one JSON blob in
/// UserDefaults (results are small).
enum SearchCache {
    /// Bumped to v2 when the abstract gained provenance (`abstractSource`). A v1 entry decodes with a
    /// nil source, which the abstract gate reads as "unverifiable, keep", so stale entries would
    /// silently bypass the gate for up to seven days. Invalidating is cheaper than special-casing.
    private static let storeKey = "search.cache.v2"
    private static let legacyStoreKey = "search.cache.v1"
    private static let ttl: TimeInterval = 7 * 24 * 3600

    private struct Entry: Codable {
        let date: Date
        let abstract: String?
        /// Optional so entries written before provenance existed still decode (they come back with a
        /// nil source, which the abstract gate treats as unverifiable rather than as on-topic).
        var abstractSource: String?
        let hits: [WebSourcesProvider.Hit]
    }

    static func get(_ query: String) -> (abstract: String?, abstractSource: String?, hits: [WebSourcesProvider.Hit])? {
        var map = load()
        guard let entry = map[normalize(query)] else { return nil }
        if Date().timeIntervalSince(entry.date) > ttl {
            map[normalize(query)] = nil
            save(map)
            return nil
        }
        return (entry.abstract, entry.abstractSource, entry.hits)
    }

    static func set(_ query: String, abstract: String?, abstractSource: String?,
                    hits: [WebSourcesProvider.Hit]) {
        var map = load()
        map[normalize(query)] = Entry(date: Date(), abstract: abstract,
                                      abstractSource: abstractSource, hits: hits)
        let now = Date()
        map = map.filter { now.timeIntervalSince($0.value.date) <= ttl }   // prune expired
        save(map)
    }

    // MARK: - Storage

    private static func normalize(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func load() -> [String: Entry] {
        if UserDefaults.standard.object(forKey: legacyStoreKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyStoreKey)   // one-time, then the read is free
        }
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: Entry]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
