import Foundation

/// Budget guard for search sources with limited free tiers (search packages with `limits`). Enforces a
/// monthly cap (the free tier) and a daily one (pacing, so a busy day can't drain the month). Counters
/// are keyed by the package id and the month/day, so they reset as time rolls over, and they outlive
/// the package: Tavily's and SerpApi's counts from before they became packages carry over, and
/// removing and reinstalling can't spend a free tier twice.
enum SearchQuota {
    static func canUse(_ source: String, limits: PackageLimits?) -> Bool {
        guard let limits else { return true }
        if let monthly = limits.monthly, usedMonth(source) >= monthly { return false }
        if let daily = limits.daily, usedToday(source) >= daily { return false }
        return true
    }

    static func usedMonth(_ source: String) -> Int {
        UserDefaults.standard.integer(forKey: monthKey(source))
    }

    static func usedToday(_ source: String) -> Int {
        UserDefaults.standard.integer(forKey: dayKey(source))
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
