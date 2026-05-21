import Foundation

public struct CodexUsageBucket: Equatable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let windowSeconds: Double?
    public let resetAt: TimeInterval?

    public var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let shortTerm: CodexUsageBucket?
    public let weekly: CodexUsageBucket?
    public let monthly: CodexUsageBucket?
    public let observedAt: Date
    public let source: String

    public var hasVisibleBuckets: Bool {
        shortTerm != nil || weekly != nil || monthly != nil
    }
}

public enum CodexUsageParser {
    public static func snapshot(from data: Data, observedAt: Date = Date(), source: String = "live") -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return snapshot(from: object, observedAt: observedAt, source: source)
    }

    public static func snapshot(from object: [String: Any], observedAt: Date = Date(), source: String = "live") -> CodexUsageSnapshot? {
        let rateLimit = object["rate_limit"] as? [String: Any]
            ?? object["limits"] as? [String: Any]
            ?? object["rate_limits"] as? [String: Any]
        let buckets = buckets(from: rateLimit)
            + additionalBuckets(from: object["additional_rate_limits"])
        let shortTerm = bestBucket(in: buckets, minimumDays: 0, maximumDays: 1, fallbackLabel: "short")
        let weekly = bestBucket(in: buckets, minimumDays: 5, maximumDays: 10, fallbackLabel: "weekly")
        let monthly = bestBucket(in: buckets, minimumDays: 20, maximumDays: 45, fallbackLabel: "monthly")
        guard shortTerm != nil || weekly != nil || monthly != nil else {
            return nil
        }
        return CodexUsageSnapshot(shortTerm: shortTerm, weekly: weekly, monthly: monthly, observedAt: observedAt, source: source)
    }

    private static func buckets(from rateLimit: [String: Any]?) -> [CodexUsageBucket] {
        guard let rateLimit else { return [] }
        return [
            bucket(from: rateLimit["primary"] ?? rateLimit["primary_window"], fallbackLabel: "primary"),
            bucket(from: rateLimit["secondary"] ?? rateLimit["secondary_window"], fallbackLabel: "secondary"),
            bucket(from: rateLimit["additional"], fallbackLabel: "additional")
        ].compactMap { $0 }
    }

    private static func additionalBuckets(from value: Any?) -> [CodexUsageBucket] {
        if let array = value as? [[String: Any]] {
            return array.flatMap { item in
                buckets(from: item["rate_limit"] as? [String: Any])
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap { item -> [CodexUsageBucket] in
                guard let rateLimit = item as? [String: Any] else { return [] }
                return buckets(from: rateLimit)
            }
        }
        return []
    }

    private static func bucket(from value: Any?, fallbackLabel: String) -> CodexUsageBucket? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = number(dictionary["used_percent"]) else {
            return nil
        }
        let windowSeconds = number(dictionary["limit_window_seconds"])
            ?? number(dictionary["window_minutes"]).map { $0 * 60.0 }
        let resetAt = number(dictionary["reset_at"])
        return CodexUsageBucket(
            label: windowSeconds.map(label(forWindowSeconds:)) ?? fallbackLabel,
            usedPercent: min(max(usedPercent, 0.0), 100.0),
            windowSeconds: windowSeconds,
            resetAt: resetAt
        )
    }

    private static func bestBucket(
        in buckets: [CodexUsageBucket],
        minimumDays: Double,
        maximumDays: Double,
        fallbackLabel: String
    ) -> CodexUsageBucket? {
        let minimumSeconds = minimumDays * 24.0 * 60.0 * 60.0
        let maximumSeconds = maximumDays * 24.0 * 60.0 * 60.0
        if let match = buckets.first(where: { bucket in
            guard let seconds = bucket.windowSeconds else { return false }
            return seconds >= minimumSeconds && seconds <= maximumSeconds
        }) {
            return match
        }
        return buckets.first { $0.label.localizedCaseInsensitiveContains(fallbackLabel) }
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

    private static func label(forWindowSeconds seconds: Double) -> String {
        let days = Int((seconds / 86_400.0).rounded())
        if days >= 1 {
            return "\(days)d"
        }
        let hours = Int((seconds / 3_600.0).rounded())
        if hours >= 1 {
            return "\(hours)h"
        }
        return "\(Int((seconds / 60.0).rounded()))m"
    }
}
