import Foundation

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let fiveHour: CodexUsageBucket?
    public let sevenDay: CodexUsageBucket?
    public let modelLimits: [ClaudeModelUsageLimit]
    public let fiveHourObservedAt: Date?
    public let sevenDayObservedAt: Date?
    public let observedAt: Date
    public let source: String

    public init(
        fiveHour: CodexUsageBucket?,
        sevenDay: CodexUsageBucket?,
        modelLimits: [ClaudeModelUsageLimit],
        fiveHourObservedAt: Date?,
        sevenDayObservedAt: Date?,
        observedAt: Date,
        source: String
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.modelLimits = modelLimits
        self.fiveHourObservedAt = fiveHourObservedAt
        self.sevenDayObservedAt = sevenDayObservedAt
        self.observedAt = observedAt
        self.source = source
    }

    public var hasVisibleBuckets: Bool {
        fiveHour != nil || sevenDay != nil || !modelLimits.isEmpty
    }

    public static func merged(
        statuslineSnapshot: ClaudeUsageSnapshot?,
        modelLimitsSnapshot: ClaudeUsageSnapshot?
    ) -> ClaudeUsageSnapshot? {
        guard statuslineSnapshot != nil || modelLimitsSnapshot != nil else {
            return nil
        }
        let fiveHourUsesStatusline = statuslineSnapshot?.fiveHour != nil
        let sevenDayUsesStatusline = statuslineSnapshot?.sevenDay != nil
        return ClaudeUsageSnapshot(
            fiveHour: statuslineSnapshot?.fiveHour ?? modelLimitsSnapshot?.fiveHour,
            sevenDay: statuslineSnapshot?.sevenDay ?? modelLimitsSnapshot?.sevenDay,
            modelLimits: modelLimitsSnapshot?.modelLimits ?? [],
            fiveHourObservedAt: fiveHourUsesStatusline
                ? statuslineSnapshot?.fiveHourObservedAt
                : modelLimitsSnapshot?.fiveHourObservedAt,
            sevenDayObservedAt: sevenDayUsesStatusline
                ? statuslineSnapshot?.sevenDayObservedAt
                : modelLimitsSnapshot?.sevenDayObservedAt,
            observedAt: statuslineSnapshot?.observedAt ?? modelLimitsSnapshot?.observedAt ?? Date(),
            source: [statuslineSnapshot?.source, modelLimitsSnapshot?.source]
                .compactMap { $0 }
                .joined(separator: "+")
        )
    }
}

public struct ClaudeModelUsageLimit: Equatable, Sendable {
    public let displayName: String
    public let bucket: CodexUsageBucket
    public let observedAt: Date
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
        return ClaudeUsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            modelLimits: [],
            fiveHourObservedAt: fiveHour == nil ? nil : observedAt,
            sevenDayObservedAt: sevenDay == nil ? nil : observedAt,
            observedAt: observedAt,
            source: source
        )
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

/// Parses the direct Claude Code get_usage cache written by
/// claude-model-limits-fetch.mjs. It is intentionally separate from the
/// statusline parser because the two files have distinct freshness contracts.
public enum ClaudeModelLimitsParser {
    public static let maxCacheAge: TimeInterval = 24 * 60 * 60

    public static func snapshot(from data: Data, now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return snapshot(from: object, now: now)
    }

    public static func snapshot(from object: [String: Any], now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard let fetchedAt = number(object["fetched_at"]) else {
            return nil
        }
        let observedAt = Date(timeIntervalSince1970: fetchedAt)
        guard now.timeIntervalSince(observedAt) >= 0,
              now.timeIntervalSince(observedAt) <= maxCacheAge else {
            return nil
        }

        let rateLimitSnapshot = ClaudeUsageParser.snapshot(
            from: object,
            observedAt: observedAt,
            source: object["source"] as? String ?? "get_usage-cache"
        )
        let modelLimits = (object["model_limits"] as? [[String: Any]] ?? []).compactMap { item -> ClaudeModelUsageLimit? in
            guard let displayName = item["display_name"] as? String,
                  !displayName.isEmpty,
                  let usedPercentage = number(item["used_percentage"]) else {
                return nil
            }
            return ClaudeModelUsageLimit(
                displayName: displayName,
                bucket: CodexUsageBucket(
                    label: "W",
                    usedPercent: min(max(usedPercentage, 0.0), 100.0),
                    windowSeconds: ClaudeUsageParser.sevenDayWindowSeconds,
                    resetAt: number(item["resets_at"])
                ),
                observedAt: observedAt
            )
        }
        guard rateLimitSnapshot != nil || !modelLimits.isEmpty else {
            return nil
        }
        return ClaudeUsageSnapshot(
            fiveHour: rateLimitSnapshot?.fiveHour,
            sevenDay: rateLimitSnapshot?.sevenDay,
            modelLimits: modelLimits,
            fiveHourObservedAt: rateLimitSnapshot?.fiveHourObservedAt,
            sevenDayObservedAt: rateLimitSnapshot?.sevenDayObservedAt,
            observedAt: observedAt,
            source: object["source"] as? String ?? "get_usage-cache"
        )
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
