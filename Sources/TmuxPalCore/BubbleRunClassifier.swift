import Foundation

public enum BubbleRunState: Equatable, Sendable {
    case running
    case complete
}

public struct BubbleRunClassifier: Sendable {
    public init() {}

    public func classify(_ bubble: PaneBubble) -> BubbleRunState {
        if bubble.pane.status == .running {
            return .running
        }

        if let event = bubble.lastEvent?.event, event.contains("exited") || event.contains("died") {
            return .complete
        }

        let fullText = [
            bubble.summary,
            bubble.pane.transcriptExcerpt,
            bubble.pane.transcriptTail,
            bubble.pane.title
        ].joined(separator: "\n").lowercased()

        let lastRunning = lastMarkerIndex(
            in: fullText,
            markers: [
                "esc to interrupt",
                "esc to cancel",
                "interrupt to stop",
                "• working",
                "\nworking (",
                " working (",
                "running command",
                "running shell command",
                "\n⠋ ",
                "\n✻ ",
                "\n✽ ",
                "\n◇ ",
                "thinking",
                "analyzing",
                "processing",
                "running..."
            ]
        )
        let lastStopped = lastMarkerIndex(
            in: fullText,
            markers: [
                "worked for",
                "task complete",
                "no active agents",
                "nothing to do",
                "exited"
            ]
        )
        if let lastRunning, lastRunning > (lastStopped ?? -1) {
            return .running
        }

        if bubble.pane.tool == .codex {
            let lastPrompt = lastMarkerIndex(
                in: fullText,
                markers: ["\n› ", "\n❯", "╰─ ❯"]
            )
            if let lastPrompt, lastPrompt > (lastRunning ?? -1) {
                return .complete
            }
        }

        return .complete
    }

    private func lastMarkerIndex(in text: String, markers: [String]) -> Int? {
        let nsText = text as NSString
        let indexes = markers.compactMap { marker -> Int? in
            let range = nsText.range(of: marker, options: [.backwards])
            return range.location == NSNotFound ? nil : range.location
        }
        return indexes.max()
    }
}
