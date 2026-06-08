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

    // v2: dropped the reverse-image `matches` field (TinEye/WebView path removed).
    private static let storeKey = "identify.cache.v2"
    private static let ttl: TimeInterval = 30 * 24 * 3600
    private static let maxEntries = 40

    /// Stable content hash of the crop (downscaled so trivial size differences still match).
    static func hash(_ image: CGImage) -> String {
        let scaled = image.downscaled(maxEdge: 256)
        let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) ?? Data()
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
