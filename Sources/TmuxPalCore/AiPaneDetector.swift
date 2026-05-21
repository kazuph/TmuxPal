import Foundation

public struct AiPaneDetector: Sendable {
    public init() {}

    public func detect(command: String, title: String, commandLine: String) -> AiTool? {
        let haystack = " \(command) \(title) \(commandLine) ".lowercased()
        let normalizedCommand = command.lowercased()

        if normalizedCommand == "copilot" || haystack.contains("/copilot") || haystack.contains(" copilot ") {
            return .copilot
        }
        if normalizedCommand == "opencode" || haystack.contains("/opencode") || haystack.contains(" opencode ") {
            return .opencode
        }
        if normalizedCommand == "claude" || haystack.contains("/claude") || haystack.contains(" claude ") || haystack.contains("claude code") {
            return .claude
        }
        if normalizedCommand == "codex" || haystack.contains("/bin/codex") || haystack.contains(" codex ") || haystack.contains("codex:") {
            return .codex
        }

        return nil
    }
}

public struct BubbleSummarizer: Sendable {
    public init() {}

    public func summarize(_ pane: TmuxPane, event: TmuxHookEvent?) -> String {
        let headline = label(for: pane)
        if let event, event.event.contains("exited") || event.event.contains("died") {
            return "\(headline)\n終了"
        }

        let excerpt = clean(pane.transcriptExcerpt)
        if !excerpt.isEmpty, !isNoise(excerpt, pane: pane) {
            return "\(headline)\n\(excerpt)"
        }

        let cleanedTitle = clean(pane.title)
        if !cleanedTitle.isEmpty, !isNoise(cleanedTitle, pane: pane) {
            return "\(headline)\n\(cleanedTitle)"
        }
        return "\(headline)\n\(pane.currentCommand)"
    }

    private func label(for pane: TmuxPane) -> String {
        let repo = URL(fileURLWithPath: pane.currentPath).lastPathComponent
        if !repo.isEmpty {
            return repo
        }
        if !pane.windowName.isEmpty {
            return pane.windowName
        }
        return "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
    }

    private func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNoise(_ value: String, pane: TmuxPane) -> Bool {
        let lower = value.lowercased()
        return lower == pane.currentCommand.lowercased()
            || lower == pane.paneId.lowercased()
            || lower == pane.paneId.dropFirst().lowercased()
            || (lower.contains("\"id\":\"cli:") && lower.contains("\"result\":"))
            || lower == "zsh"
            || lower == "bash"
    }
}
