import Foundation
import MLX
import MLXLMCommon

/// Keeps the model's state after reading the stable start of a conversation, so the next request reads
/// only what's new.
///
/// Hermes sends ~14k tokens of instructions and tool definitions with every request, then the whole
/// conversation. A local model reading all of it every time is what made an Agent reply take minutes.
/// Each request is read in two parts: everything before its last message (saved), then the last message
/// and the reply. The next request (the tool result, or the user's next turn) starts with the saved
/// part, so only the difference is read.
///
/// A few saved states, not one: Hermes's side requests (a title, a summary) start differently and would
/// otherwise push out the Agent's. A state that a new one extends (the same conversation, further on) is
/// replaced; otherwise the least recently used goes. Cleared when the model is unloaded.
final class MLXPromptCache: @unchecked Sendable {
    static let shared = MLXPromptCache()

    private struct Entry {
        var owner: ObjectIdentifier
        var tokens: [Int]
        var state: [any KVCache]
        var used: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 3) { self.capacity = capacity }

    var isEmpty: Bool { lock.withLock { entries.isEmpty } }

    /// A copy of the longest saved state that `prompt` starts with, and how many tokens it covers.
    func restore(for container: ModelContainer, prompt: [Int]) -> (cache: [any KVCache], covered: Int)? {
        lock.withLock {
            let owner = ObjectIdentifier(container)
            guard let index = entries.indices
                .filter({ entries[$0].owner == owner && Self.isPrefix(entries[$0].tokens, of: prompt) })
                .max(by: { entries[$0].tokens.count < entries[$1].tokens.count }) else { return nil }
            entries[index].used = Date()
            return (entries[index].state.map { $0.copy() }, entries[index].tokens.count)
        }
    }

    /// Saves a copy of `cache`, which holds exactly `tokens`.
    func save(for container: ModelContainer, tokens: [Int], cache: [any KVCache]) {
        let entry = Entry(owner: ObjectIdentifier(container), tokens: tokens, state: cache.map { $0.copy() }, used: Date())
        lock.withLock {
            entries.removeAll { $0.owner != entry.owner || Self.isPrefix($0.tokens, of: tokens) }
            if entries.count >= capacity, let oldest = entries.indices.min(by: { entries[$0].used < entries[$1].used }) {
                entries.remove(at: oldest)
            }
            entries.append(entry)
        }
    }

    func clear() {
        lock.withLock { entries.removeAll() }
    }

    /// Length of the shared start of two token sequences.
    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    static func isPrefix(_ a: [Int], of b: [Int]) -> Bool {
        !a.isEmpty && a.count < b.count && commonPrefix(a, b) == a.count
    }
}
