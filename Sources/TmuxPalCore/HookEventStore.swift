import Foundation

public struct HookEventStore: Sendable {
    public let eventsURL: URL

    public init(eventsURL: URL = HookEventStore.defaultEventsURL()) {
        self.eventsURL = eventsURL
    }

    public static func defaultEventsURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tmuxpal/events.jsonl")
    }

    public func readRecent(limit: Int = 200) -> [TmuxHookEvent] {
        guard let data = try? Data(contentsOf: eventsURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line in
                try? decoder.decode(TmuxHookEvent.self, from: Data(line.utf8))
            }
    }

    public func latestEventsByPane(limit: Int = 200) -> [String: TmuxHookEvent] {
        latestEventsByPane(limit: limit, maxAge: nil)
    }

    public func latestEventsByPane(limit: Int = 200, maxAge: TimeInterval?) -> [String: TmuxHookEvent] {
        let now = Date()
        var latest: [String: TmuxHookEvent] = [:]
        for event in readRecent(limit: limit) {
            if let maxAge, now.timeIntervalSince(event.createdAt) > maxAge {
                continue
            }
            latest[event.paneId] = event
        }
        return latest
    }
}
