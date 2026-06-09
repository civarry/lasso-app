import Foundation
import CoreGraphics
import AppKit
import CryptoKit

/// Caches a completed Identify result keyed by the crop's content hash, so re-identifying the same
/// image is instant and spends zero web quota (no vision call, no web lookup, no synthesis).
enum IdentifyCache {
    struct Entry: Codable {
        let date: Date
        let summary: String
        let visionText: String
        let abstract: String?
        let webHits: [WebSourcesProvider.Hit]
    }

    // v3: cache key now folds in the active model/source config (see `hash`).
    private static let storeKey = "identify.cache.v3"
    private static let ttl: TimeInterval = 30 * 24 * 3600
    private static let maxEntries = 40

    /// Stable content hash of the crop (downscaled so trivial size differences still match), combined
    /// with a `signature` of the active model/source config so a different setup yields a different
    /// key (no stale result after switching engine/model/connectors).
    static func hash(_ image: CGImage, signature: String = "") -> String {
        let scaled = image.downscaled(maxEdge: 256)
        var data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) ?? Data()
        data.append(Data(signature.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func get(_ key: String) -> Entry? {
        var map = load()
        guard let entry = map[key] else { return nil }
        if Date().timeIntervalSince(entry.date) > ttl {
            map[key] = nil
            save(map)
            return nil
        }
        return entry
    }

    static func set(_ key: String, _ entry: Entry) {
        var map = load()
        map[key] = entry
        let now = Date()
        map = map.filter { now.timeIntervalSince($0.value.date) <= ttl }   // drop expired
        if map.count > maxEntries {                                        // keep newest
            let newest = map.sorted { $0.value.date > $1.value.date }.prefix(maxEntries)
            map = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        save(map)
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
