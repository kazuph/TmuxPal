import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stdoutHandle = output.fileHandleForReading
        let stderrHandle = error.fileHandleForReading
        let data = stdoutHandle.readDataToEndOfFile()
        let errorData = stderrHandle.readDataToEndOfFile()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "command failed"
            throw TmuxCollectorError.commandFailed(errorText)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum TmuxCollectorError: Error, LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

public struct TmuxClient: Equatable, Sendable {
    public let name: String
    public let sessionName: String
    public let windowIndex: String
    public let paneIndex: String

    public init(name: String, sessionName: String, windowIndex: String, paneIndex: String) {
        self.name = name
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
    }
}

public struct TmuxCollector: Sendable {
    public static let fieldSeparator = "|#|"

    private let tmuxPath: String
    private let tmuxSocketPath: String?
    private let runner: CommandRunning
    private let detector: AiPaneDetector

    public init(
        tmuxPath: String = "/opt/homebrew/bin/tmux",
        tmuxSocketPath: String? = nil,
        runner: CommandRunning = ProcessCommandRunner(),
        detector: AiPaneDetector = AiPaneDetector()
    ) {
        self.tmuxPath = tmuxPath
        self.tmuxSocketPath = tmuxSocketPath ?? Self.defaultSocketPath()
        self.runner = runner
        self.detector = detector
    }

    public func collect() throws -> [TmuxPane] {
        let format = [
            "#{session_name}",
            "#{window_index}",
            "#{window_id}",
            "#{window_name}",
            "#{pane_index}",
            "#{pane_id}",
            "#{pane_pid}",
            "#{pane_tty}",
            "#{pane_current_command}",
            "#{pane_current_path}",
            "#{pane_active}",
            "#{pane_title}"
        ].joined(separator: Self.fieldSeparator)

        let output = try runTmux(["list-panes", "-a", "-F", format])
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let text = String(line)
                let pane = parseLine(text) ?? parseLine(text, commandLineOverride: processCommandLines(forTmuxLine: text))
                if let pane {
                    let transcript = captureTranscript(for: pane.paneId)
                    return pane.withTranscript(snippet: summarizeTranscript(transcript), tail: transcript)
                }
                return nil
            }
    }

    public func parseListPanes(_ output: String, observedAt: Date = Date()) -> [TmuxPane] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in parseLine(String(line), observedAt: observedAt) }
    }

    public func parseLine(_ line: String, observedAt: Date = Date(), commandLineOverride: String? = nil) -> TmuxPane? {
        let parts = line.components(separatedBy: Self.fieldSeparator)
        guard parts.count >= 12 else {
            return nil
        }

        let command = parts[8]
        let title = parts[11]
        let commandLine = commandLineOverride ?? commandLineFromTitleOrCommand(title: title, command: command)
        guard let tool = detector.detect(command: command, title: title, commandLine: commandLine) else {
            return nil
        }

        return TmuxPane(
            sessionName: parts[0],
            windowIndex: parts[1],
            windowId: parts[2],
            windowName: parts[3],
            paneIndex: parts[4],
            paneId: parts[5],
            panePid: parts[6],
            paneTty: parts[7],
            currentCommand: command,
            currentPath: parts[9],
            active: parts[10] == "1",
            title: title,
            commandLine: commandLine,
            tool: tool,
            status: parts[10] == "1" ? .selected : .running,
            observedAt: observedAt
        )
    }

    private func commandLineFromTitleOrCommand(title: String, command: String) -> String {
        if title.contains("/bin/") || title.contains(" --") {
            return title
        }
        return command
    }

    private func processCommandLines(forTmuxLine line: String) -> String? {
        let parts = line.components(separatedBy: Self.fieldSeparator)
        guard parts.count >= 8 else {
            return nil
        }
        let tty = parts[7].replacingOccurrences(of: "/dev/", with: "")
        guard !tty.isEmpty else {
            return nil
        }
        return try? runner.run("/bin/ps", ["-o", "pid=,ppid=,comm=,command=", "-t", tty])
    }

    private func captureTranscript(for paneId: String) -> String {
        guard let output = try? runTmux(["capture-pane", "-p", "-J", "-t", paneId, "-S", "-24"]) else {
            return ""
        }
        return output
    }

    private func summarizeTranscript(_ output: String) -> String {
        let noise = [
            "esc to interrupt",
            "esc to cancel",
            "enter to confirm",
            "to select",
            "ctrl-c",
            "ctrl+d",
            "tokens",
            "context left",
            "auto",
            "worked for",
            "queued retries"
        ]
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                if noise.contains(where: lower.contains) {
                    return false
                }
                let usefulScalars = line.unicodeScalars.filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || CharacterSet(charactersIn: "ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもやゃゆゅよょらりるれろわをん一-龯").contains(scalar)
                }
                return usefulScalars.count >= 8
            }
            .suffix(3)
            .joined(separator: " ")
            .split(separator: " ")
            .prefix(28)
            .joined(separator: " ")
    }

    public func focus(_ pane: TmuxPane) throws {
        let target = "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
        if let client = try preferredClient(for: pane) {
            _ = try runTmux(["switch-client", "-c", client.name, "-t", target])
        } else {
            _ = try runTmux(["select-window", "-t", "\(pane.sessionName):\(pane.windowIndex)"])
        }
        _ = try runTmux(["select-pane", "-t", pane.paneId])
    }

    public func parseListClients(_ output: String) -> [TmuxClient] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = String(line).components(separatedBy: Self.fieldSeparator)
                guard parts.count >= 4, !parts[0].isEmpty else {
                    return nil
                }
                return TmuxClient(name: parts[0], sessionName: parts[1], windowIndex: parts[2], paneIndex: parts[3])
            }
    }

    private func preferredClient(for pane: TmuxPane) throws -> TmuxClient? {
        let format = [
            "#{client_name}",
            "#{session_name}",
            "#{window_index}",
            "#{pane_index}"
        ].joined(separator: Self.fieldSeparator)
        let clients = parseListClients(try runTmux(["list-clients", "-F", format]))
        guard !clients.isEmpty else {
            return nil
        }
        if let sameSession = clients.first(where: { $0.sessionName == pane.sessionName }) {
            return sameSession
        }
        if let mainSession = clients.first(where: { $0.sessionName == "0" }) {
            return mainSession
        }
        return clients.first
    }

    private func runTmux(_ arguments: [String]) throws -> String {
        if let tmuxSocketPath {
            return try runner.run(tmuxPath, ["-S", tmuxSocketPath] + arguments)
        }
        return try runner.run(tmuxPath, arguments)
    }

    private static func defaultSocketPath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["TMUX_AI_PET_TMUX_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        let uid = getuid()
        let path = "/private/tmp/tmux-\(uid)/default"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }
}
