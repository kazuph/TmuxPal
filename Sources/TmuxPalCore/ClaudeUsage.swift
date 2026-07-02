import Foundation

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let fiveHour: CodexUsageBucket?
    public let sevenDay: CodexUsageBucket?
    public let observedAt: Date
    public let source: String

    public var hasVisibleBuckets: Bool {
        fiveHour != nil || sevenDay != nil
    }
}

/// Parses Claude Code rate-limit payloads. Accepts both the statusline JSON
/// (`{"rate_limits": {...}}`, cached by ~/.claude/statusline.sh) and the bare
/// `rate_limits` object, with `used_percentage` or `utilization` per bucket.
public enum ClaudeUsageParser {
    static let fiveHourWindowSeconds: Double = 5 * 60 * 60
    static let sevenDayWindowSeconds: Double = 7 * 24 * 60 * 60

    public static func snapshot(from data: Data, observedAt: Date = Date(), source: String = "cache") -> ClaudeUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return snapshot(from: object, observedAt: observedAt, source: source)
    }

    public static func snapshot(from object: [String: Any], observedAt: Date = Date(), source: String = "cache") -> ClaudeUsageSnapshot? {
        let rateLimits = object["rate_limits"] as? [String: Any] ?? object
        let fiveHour = bucket(
            from: firstValue(
                in: rateLimits,
                keys: ["five_hour", "fiveHour", "5h", "short_term", "shortTerm"]
            ),
            label: "5h",
            windowSeconds: fiveHourWindowSeconds
        )
        let sevenDay = bucket(
            from: firstValue(
                in: rateLimits,
                keys: ["seven_day", "sevenDay", "weekly", "7d", "week"]
            ),
            label: "W",
            windowSeconds: sevenDayWindowSeconds
        )
        guard fiveHour != nil || sevenDay != nil else {
            return nil
        }
        return ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, observedAt: observedAt, source: source)
    }

    private static func firstValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
        }
        return nil
    }

    private static func bucket(from value: Any?, label: String, windowSeconds: Double) -> CodexUsageBucket? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = usedPercent(from: dictionary) else {
            return nil
        }
        return CodexUsageBucket(
            label: label,
            usedPercent: min(max(usedPercent, 0.0), 100.0),
            windowSeconds: windowSeconds,
            resetAt: resetAt(from: dictionary["resets_at"] ?? dictionary["reset_at"])
        )
    }

    private static func usedPercent(from dictionary: [String: Any]) -> Double? {
        if let percent = number(dictionary["used_percentage"])
            ?? number(dictionary["used_percent"])
            ?? number(dictionary["percent"])
            ?? number(dictionary["percentage"])
        {
            return percent
        }
        if let utilization = number(dictionary["utilization"]) {
            // Some payloads report a 0...1 fraction, others a 0...100 percentage.
            return utilization <= 1.0 ? utilization * 100.0 : utilization
        }
        return nil
    }

    private static func resetAt(from value: Any?) -> Double? {
        if let epoch = number(value) {
            return epoch
        }
        if let text = value as? String {
            if let epoch = Double(text) {
                return epoch
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return date.timeIntervalSince1970
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) {
                return date.timeIntervalSince1970
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}
