import Foundation
import CoreFoundation

struct AccountTokenDay: Identifiable, Equatable {
    /// The server's day label; no timezone conversion is applied.
    let startDate: String
    let tokens: Int64
    var id: String { startDate }
}

struct AccountTokenUsageSnapshot {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    /// nil means unavailable; an empty array means the server returned no days.
    let days: [AccountTokenDay]?
    let checkedAt: Date

    static func parse(_ result: [String: Any], checkedAt: Date = Date()) throws -> Self {
        var summary: [String: Any] = [:]
        if let raw = result["summary"], !(raw is NSNull) {
            guard let fields = raw as? [String: Any] else { throw invalid("summary") }
            summary = fields
        }
        let lifetime = try optionalCount(summary["lifetimeTokens"], field: "lifetimeTokens")
        let peak = try optionalCount(summary["peakDailyTokens"], field: "peakDailyTokens")
        var days: [AccountTokenDay]?
        if let raw = result["dailyUsageBuckets"], !(raw is NSNull) {
            guard let buckets = raw as? [[String: Any]] else { throw invalid("dailyUsageBuckets") }
            var seen = Set<String>()
            days = try buckets.map { bucket in
                guard let day = bucket["startDate"] as? String, validDay(day), seen.insert(day).inserted,
                      let count = try optionalCount(bucket["tokens"], field: "daily tokens") else {
                    throw invalid("daily usage bucket")
                }
                return AccountTokenDay(startDate: day, tokens: count)
            }.sorted { $0.startDate > $1.startDate }
        }
        return Self(lifetimeTokens: lifetime, peakDailyTokens: peak, days: days, checkedAt: checkedAt)
    }

    private static func optionalCount(_ raw: Any?, field: String) throws -> Int64? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int64(number.stringValue), count >= 0 else { throw invalid(field) }
        return count
    }

    private static func validDay(_ day: String) -> Bool {
        guard day.utf8.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
    }

    private static func invalid(_ field: String) -> NSError {
        NSError(domain: "CodexAccountUsage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid account usage field: \(field)"])
    }

    static func selfCheck() -> [String] {
        var failures: [String] = []
        do {
            let json = """
            {"summary":{"lifetimeTokens":9007199254740993,"peakDailyTokens":42},
             "dailyUsageBuckets":[{"startDate":"2026-10-06","tokens":0},{"startDate":"2026-10-07","tokens":42}],
             "threadUsage":[{"ignored":"private thread data"}]}
            """
            let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let snapshot = try parse(result)
            if snapshot.lifetimeTokens != 9_007_199_254_740_993 || snapshot.peakDailyTokens != 42 ||
                snapshot.days != [AccountTokenDay(startDate: "2026-10-07", tokens: 42), AccountTokenDay(startDate: "2026-10-06", tokens: 0)] {
                failures.append("Account counters or server day labels changed")
            }
            let missing = try parse(["summary": NSNull(), "dailyUsageBuckets": NSNull()])
            if missing.lifetimeTokens != nil || missing.peakDailyTokens != nil || missing.days != nil {
                failures.append("Unavailable account usage must not become zero")
            }
            if try parse(["dailyUsageBuckets": []]).days != [] { failures.append("Empty account history changed") }
        } catch { failures.append("Valid account usage failed: \(error.localizedDescription)") }
        let invalidResults: [[String: Any]] = [
            ["summary": ["lifetimeTokens": -1]], ["summary": ["peakDailyTokens": true]],
            ["summary": ["lifetimeTokens": 1.5]], ["summary": ["lifetimeTokens": "42"]],
            ["summary": ["lifetimeTokens": NSNumber(value: UInt64.max)]], ["summary": []],
            ["dailyUsageBuckets": [["startDate": "2026-02-30", "tokens": 1]]],
            ["dailyUsageBuckets": [["startDate": "2026-10-07", "tokens": NSNull()]]],
            ["dailyUsageBuckets": [["startDate": "2026-10-07", "tokens": 1], ["startDate": "2026-10-07", "tokens": 2]]]
        ]
        for result in invalidResults {
            do { _ = try parse(result); failures.append("Invalid account usage was accepted") }
            catch { }
        }
        return failures
    }
}
