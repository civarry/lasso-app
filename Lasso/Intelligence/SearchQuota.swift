import Foundation

/// Budget guard for limited-quota search APIs (Tavily, SerpApi). Enforces both a monthly cap (free
/// tier) and a daily cap (pacing, so a busy day can't drain the month). Counters are keyed by
/// month/day, so they reset automatically as time rolls over.
enum SearchQuota {
    /// (monthly, daily) caps per source, kept just under each free tier with daily pacing.
    /// Tavily: 1,000 credits/mo (basic search = 1 credit). SerpApi: 250 searches/mo.
    static let caps: [String: (monthly: Int, daily: Int)] = [
        "tavily": (monthly: 960, daily: 40),
        "serpapi": (monthly: 240, daily: 10),
    ]

    static func canUse(_ source: String) -> Bool {
        guard let cap = caps[source] else { return false }
        return usedMonth(source) < cap.monthly && usedToday(source) < cap.daily
    }

    static func usedMonth(_ source: String) -> Int {
        UserDefaults.standard.integer(forKey: monthKey(source))
    }

    static func usedToday(_ source: String) -> Int {
        UserDefaults.standard.integer(forKey: dayKey(source))
    }

    static func remainingMonth(_ source: String) -> Int {
        max(0, (caps[source]?.monthly ?? 0) - usedMonth(source))
    }

    /// Record one consumed request (call after a successful API response).
    static func record(_ source: String) {
        bump(monthKey(source))
        bump(dayKey(source))
    }

    // MARK: - Keys

    private static func monthKey(_ source: String) -> String { "quota.\(source).M.\(stamp("yyyy-MM"))" }
    private static func dayKey(_ source: String) -> String { "quota.\(source).D.\(stamp("yyyy-MM-dd"))" }

    private static func stamp(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }

    private static func bump(_ key: String) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}
