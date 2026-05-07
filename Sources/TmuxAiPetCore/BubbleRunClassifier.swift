import Foundation

public enum BubbleRunState: Equatable, Sendable {
    case running
    case complete
}

public struct BubbleRunClassifier: Sendable {
    public init() {}

    public func classify(_ bubble: PaneBubble) -> BubbleRunState {
        if let event = bubble.lastEvent?.event, event.contains("exited") || event.contains("died") {
            return .complete
        }

        let command = bubble.pane.currentCommand.lowercased()
        if command == "zsh" || command == "bash" {
            return .complete
        }

        let fullText = [
            bubble.summary,
            bubble.pane.transcriptSnippet,
            bubble.pane.transcriptTail,
            bubble.pane.title
        ].joined(separator: "\n").lowercased()

        let lastRunning = lastMarkerIndex(
            in: fullText,
            markers: [
                "esc to interrupt",
                "interrupt to stop",
                "• working",
                "\nworking (",
                " working (",
                "running command"
            ]
        )
        let lastStopped = lastMarkerIndex(
            in: fullText,
            markers: [
                "worked for",
                "no active agents",
                "nothing to do",
                "completed",
                "done",
                "pass",
                "passed",
                "success",
                "succeeded",
                "終了"
            ]
        )
        if let lastRunning, lastRunning > (lastStopped ?? -1) {
            return .running
        }

        let lastPrompt = lastMarkerIndex(
            in: fullText,
            markers: ["\n› ", "\n❯", "╰─ ❯"]
        )
        if let lastPrompt, lastPrompt > (lastRunning ?? -1) {
            return .complete
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
