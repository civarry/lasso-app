import Foundation

/// On-device cache of web-search results keyed by normalized query, so re-identifying the same thing
/// costs zero API quota. 7-day TTL; expired entries are pruned on write. Stored as one JSON blob in
/// UserDefaults (results are small).
enum SearchCache {
    private static let storeKey = "search.cache.v1"
    private static let ttl: TimeInterval = 7 * 24 * 3600

    private struct Entry: Codable {
        let date: Date
        let abstract: String?
        let hits: [WebSourcesProvider.Hit]
    }

    static func get(_ query: String) -> (abstract: String?, hits: [WebSourcesProvider.Hit])? {
        var map = load()
        guard let entry = map[normalize(query)] else { return nil }
        if Date().timeIntervalSince(entry.date) > ttl {
            map[normalize(query)] = nil
            save(map)
            return nil
        }
        return (entry.abstract, entry.hits)
    }

    static func set(_ query: String, abstract: String?, hits: [WebSourcesProvider.Hit]) {
        var map = load()
        map[normalize(query)] = Entry(date: Date(), abstract: abstract, hits: hits)
        let now = Date()
        map = map.filter { now.timeIntervalSince($0.value.date) <= ttl }   // prune expired
        save(map)
    }

    // MARK: - Storage

    private static func normalize(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func load() -> [String: Entry] {
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
