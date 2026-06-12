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
    public static let herdrSessionName = "herdr"

    private let tmuxPath: String
    private let tmuxSocketPath: String?
    private let runner: CommandRunning
    private let detector: AiPaneDetector
    private let herdrPath: String?
    private let transcriptCache: LockedTranscriptCache
    private let inactiveTranscriptCacheTTL: TimeInterval
    private let activeTranscriptCacheTTL: TimeInterval

    public init(
        tmuxPath: String = "/opt/homebrew/bin/tmux",
        tmuxSocketPath: String? = nil,
        runner: CommandRunning = ProcessCommandRunner(),
        detector: AiPaneDetector = AiPaneDetector(),
        herdrPath: String? = nil,
        transcriptCacheTTL: TimeInterval = 12,
        activeTranscriptCacheTTL: TimeInterval = 4.5
    ) {
        self.tmuxPath = tmuxPath
        self.tmuxSocketPath = tmuxSocketPath ?? Self.defaultSocketPath()
        self.runner = runner
        self.detector = detector
        self.herdrPath = herdrPath ?? Self.defaultHerdrPath()
        self.inactiveTranscriptCacheTTL = transcriptCacheTTL
        self.activeTranscriptCacheTTL = activeTranscriptCacheTTL
        self.transcriptCache = LockedTranscriptCache()
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

        var tmuxError: Error?
        let tmuxPanes: [TmuxPane]
        do {
            let output = try runTmux(["list-panes", "-a", "-F", format])
            tmuxPanes = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let text = String(line)
                    let pane = parseLine(text) ?? parseLine(text, commandLineOverride: cachedProcessCommandLine(forTmuxLine: text))
                    if let pane {
                        let transcript = cachedTranscript(for: pane)
                        return pane.withTranscript(excerpt: transcript.excerpt, tail: transcript.tail)
                    }
                    return nil
                }
        } catch {
            tmuxError = error
            tmuxPanes = []
        }

        let herdrPanes = collectHerdrPanes()
        if tmuxPanes.isEmpty, herdrPanes.isEmpty, let tmuxError {
            throw tmuxError
        }
        return tmuxPanes + herdrPanes
    }

    public func parseHerdrAgentList(_ output: String, observedAt: Date = Date()) -> [TmuxPane] {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(HerdrAgentListResponse.self, from: data) else {
            return []
        }
        return response.result.agents.compactMap { agent in
            herdrPane(from: agent, observedAt: observedAt)
        }
    }

    public func parseHerdrPaneList(_ output: String, observedAt: Date = Date()) -> [TmuxPane] {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(HerdrPaneListResponse.self, from: data) else {
            return []
        }
        return response.result.panes.compactMap { pane in
            guard pane.agent != nil else {
                return nil
            }
            return herdrPane(from: pane, observedAt: observedAt)
        }
    }

    private func collectHerdrPanes() -> [TmuxPane] {
        let output: String
        do {
            output = try runHerdr(["agent", "list"])
        } catch {
            return []
        }
        return parseHerdrAgentList(output).map { pane in
            let transcript = cachedTranscript(for: pane)
            return pane.withTranscript(excerpt: transcript.excerpt, tail: transcript.tail)
        }
    }

    private func herdrPane(from pane: HerdrPaneSnapshot, observedAt: Date) -> TmuxPane? {
        let agent = pane.agent ?? ""
        guard let tool = detector.detect(command: agent, title: "", commandLine: agent) else {
            return nil
        }
        return TmuxPane(
            sessionName: Self.herdrSessionName,
            windowIndex: pane.workspaceId,
            windowId: pane.tabId,
            windowName: pane.workspaceId,
            paneIndex: pane.paneId,
            paneId: pane.paneId,
            panePid: "",
            paneTty: "",
            currentCommand: agent,
            currentPath: pane.cwd,
            active: pane.focused,
            title: pane.agentStatus,
            commandLine: agent,
            tool: tool,
            status: herdrStatus(pane.agentStatus, focused: pane.focused),
            observedAt: observedAt
        )
    }

    private func herdrStatus(_ status: String, focused: Bool) -> PaneStatus {
        switch status {
        case "idle":
            return focused ? .selected : .idle
        case "working", "blocked", "unknown":
            return .running
        default:
            return .running
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
            // tmux gives no reliable run signal, so leave inactive panes as
            // .idle and let BubbleRunClassifier read the transcript markers.
            // Only herdr panes report a trustworthy .running status.
            status: parts[10] == "1" ? .selected : .idle,
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

    private func cachedProcessCommandLine(forTmuxLine line: String) -> String? {
        let parts = line.components(separatedBy: Self.fieldSeparator)
        guard parts.count >= 12 else {
            return nil
        }
        let paneId = parts[5]
        let command = parts[8]
        let title = parts[11]
        guard shouldInspectProcessCommandLine(command: command, title: title) else {
            return nil
        }
        let signature = "\(command)|\(title)"
        if let cached = transcriptCache.processCommandLine(for: paneId, signature: signature) {
            return cached.isEmpty ? nil : cached
        }
        let value = processCommandLines(forTmuxLine: line)
        transcriptCache.storeProcessCommandLine(value, for: paneId, signature: signature)
        return value
    }

    private func shouldInspectProcessCommandLine(command: String, title: String) -> Bool {
        let text = "\(command) \(title)".lowercased()
        if ["codex", "claude", "copilot", "opencode"].contains(where: text.contains) {
            return true
        }
        return ["node", "bun", "deno", "npm", "npx", "pnpm", "yarn"].contains(command.lowercased())
    }

    private func captureTranscript(for paneId: String) -> String {
        if isHerdrPaneId(paneId) {
            let output = (try? runHerdr(["agent", "read", paneId, "--source", "recent-unwrapped", "--lines", "16", "--format", "text"])) ?? ""
            return Self.herdrReadText(from: output)
        }
        guard let output = try? runTmux(["capture-pane", "-p", "-J", "-t", paneId, "-S", "-16"]) else {
            return ""
        }
        return output
    }

    static func herdrReadText(from output: String) -> String {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(HerdrAgentReadResponse.self, from: data) else {
            return output
        }
        return response.result.read.text
    }

    private func cachedTranscript(for pane: TmuxPane) -> (excerpt: String, tail: String) {
        let signature = [
            pane.currentCommand,
            pane.title,
            pane.windowName,
            pane.active ? "1" : "0"
        ].joined(separator: "|")
        let maxAge = pane.active ? activeTranscriptCacheTTL : inactiveTranscriptCacheTTL
        if let cached = transcriptCache.transcript(for: pane.paneId, signature: signature, maxAge: maxAge) {
            return cached
        }
        let transcript = captureTranscript(for: pane.paneId)
        let excerpt = summarizeTranscript(transcript)
        transcriptCache.storeTranscript(excerpt: excerpt, tail: transcript, for: pane.paneId, signature: signature)
        return (excerpt, transcript)
    }

    private func summarizeTranscript(_ output: String) -> String {
        let output = Self.herdrReadText(from: output)
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
                if lower.contains("\"id\":\"cli:") && lower.contains("\"result\":") {
                    return false
                }
                if noise.contains(where: lower.contains) {
                    return false
                }
                let usefulScalars = line.unicodeScalars.filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || Self.isCJKScalar(scalar)
                }
                return usefulScalars.count >= 8
            }
            .suffix(3)
            .joined(separator: " ")
            .split(separator: " ")
            .prefix(28)
            .joined(separator: " ")
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x30ff).contains(Int(scalar.value))
            || (0x3400...0x4dbf).contains(Int(scalar.value))
            || (0x4e00...0x9fff).contains(Int(scalar.value))
    }

    public func focus(_ pane: TmuxPane) throws {
        if isHerdrPaneId(pane.paneId) || pane.sessionName == Self.herdrSessionName {
            _ = try runHerdr(["agent", "focus", pane.paneId])
            return
        }
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

    private func runHerdr(_ arguments: [String]) throws -> String {
        guard let herdrPath else {
            throw TmuxCollectorError.commandFailed("herdr executable not found")
        }
        return try runner.run(herdrPath, arguments)
    }

    private func isHerdrPaneId(_ paneId: String) -> Bool {
        paneId.hasPrefix("w") && paneId.contains("-")
    }

    private static func defaultSocketPath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["TMUXPAL_TMUX_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        let uid = getuid()
        let path = "/private/tmp/tmux-\(uid)/default"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private static func defaultHerdrPath() -> String? {
        let fileManager = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["TMUXPAL_HERDR_PATH"],
           fileManager.isExecutableFile(atPath: explicit) {
            return explicit
        }

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("herdr").path }
        let commonCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr").path,
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/usr/bin/herdr"
        ]

        return (pathCandidates + commonCandidates)
            .first { fileManager.isExecutableFile(atPath: $0) }
    }
}

private struct HerdrAgentListResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let agents: [HerdrPaneSnapshot]
    }
}

private struct HerdrPaneListResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let panes: [HerdrPaneSnapshot]
    }
}

private struct HerdrAgentReadResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let read: Read
    }

    struct Read: Decodable {
        let text: String
    }
}

private struct HerdrPaneSnapshot: Decodable {
    let agent: String?
    let agentStatus: String
    let cwd: String
    let focused: Bool
    let paneId: String
    let tabId: String
    let workspaceId: String

    private enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case cwd
        case focused
        case paneId = "pane_id"
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
    }
}

private final class LockedTranscriptCache: @unchecked Sendable {
    private struct StringEntry {
        let signature: String
        let value: String
        let createdAt: Date
    }

    private struct TranscriptEntry {
        let signature: String
        let excerpt: String
        let tail: String
        let createdAt: Date
    }

    private let lock = NSLock()
    private var transcripts: [String: TranscriptEntry] = [:]
    private var processCommandLines: [String: StringEntry] = [:]
    private let processCommandLineTTL: TimeInterval = 30

    func transcript(for paneId: String, signature: String, maxAge: TimeInterval) -> (excerpt: String, tail: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = transcripts[paneId],
              entry.signature == signature,
              Date().timeIntervalSince(entry.createdAt) < maxAge else {
            return nil
        }
        return (entry.excerpt, entry.tail)
    }

    func storeTranscript(excerpt: String, tail: String, for paneId: String, signature: String) {
        lock.lock()
        defer { lock.unlock() }
        transcripts[paneId] = TranscriptEntry(signature: signature, excerpt: excerpt, tail: tail, createdAt: Date())
    }

    func processCommandLine(for paneId: String, signature: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = processCommandLines[paneId],
              entry.signature == signature,
              Date().timeIntervalSince(entry.createdAt) < processCommandLineTTL else {
            return nil
        }
        return entry.value
    }

    func storeProcessCommandLine(_ value: String?, for paneId: String, signature: String) {
        lock.lock()
        defer { lock.unlock() }
        processCommandLines[paneId] = StringEntry(signature: signature, value: value ?? "", createdAt: Date())
    }
}
