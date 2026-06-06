import Foundation

/// Tracks monthly usage of limited-quota search APIs (Tavily, SerpApi) so we stay within their free
/// tiers. Counters are keyed by month, so they reset automatically when the month rolls over.
enum SearchQuota {
    private static func monthKey(_ source: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return "quota.\(source).\(formatter.string(from: Date()))"
    }

    static func used(_ source: String) -> Int {
        UserDefaults.standard.integer(forKey: monthKey(source))
    }

    static func remaining(_ source: String, cap: Int) -> Int {
        max(0, cap - used(source))
    }

    static func canUse(_ source: String, cap: Int) -> Bool {
        used(source) < cap
    }

    /// Record one consumed request (call after a successful API response).
    static func record(_ source: String) {
        let key = monthKey(source)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}
