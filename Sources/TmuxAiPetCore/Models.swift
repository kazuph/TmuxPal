import Foundation

public enum AiTool: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case copilot
    case opencode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .copilot: "Copilot"
        case .opencode: "opencode"
        }
    }
}

public enum PaneStatus: String, Codable, Sendable {
    case running
    case selected
    case exited
    case idle

    public var displayName: String {
        switch self {
        case .running: "実行中"
        case .selected: "選択中"
        case .exited: "終了"
        case .idle: "待機"
        }
    }
}

public struct TmuxPane: Identifiable, Codable, Equatable, Sendable {
    public var id: String { paneId }

    public let sessionName: String
    public let windowIndex: String
    public let windowId: String
    public let windowName: String
    public let paneIndex: String
    public let paneId: String
    public let panePid: String
    public let paneTty: String
    public let currentCommand: String
    public let currentPath: String
    public let active: Bool
    public let title: String
    public let commandLine: String
    public let transcriptSnippet: String
    public let tool: AiTool
    public let status: PaneStatus
    public let observedAt: Date

    public init(
        sessionName: String,
        windowIndex: String,
        windowId: String,
        windowName: String,
        paneIndex: String,
        paneId: String,
        panePid: String,
        paneTty: String,
        currentCommand: String,
        currentPath: String,
        active: Bool,
        title: String,
        commandLine: String,
        transcriptSnippet: String = "",
        tool: AiTool,
        status: PaneStatus,
        observedAt: Date = Date()
    ) {
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.windowId = windowId
        self.windowName = windowName
        self.paneIndex = paneIndex
        self.paneId = paneId
        self.panePid = panePid
        self.paneTty = paneTty
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.active = active
        self.title = title
        self.commandLine = commandLine
        self.transcriptSnippet = transcriptSnippet
        self.tool = tool
        self.status = status
        self.observedAt = observedAt
    }

    public func withTranscriptSnippet(_ snippet: String) -> TmuxPane {
        TmuxPane(
            sessionName: sessionName,
            windowIndex: windowIndex,
            windowId: windowId,
            windowName: windowName,
            paneIndex: paneIndex,
            paneId: paneId,
            panePid: panePid,
            paneTty: paneTty,
            currentCommand: currentCommand,
            currentPath: currentPath,
            active: active,
            title: title,
            commandLine: commandLine,
            transcriptSnippet: snippet,
            tool: tool,
            status: status,
            observedAt: observedAt
        )
    }
}

public struct PaneBubble: Identifiable, Equatable, Sendable {
    public var id: String { pane.paneId }
    public let pane: TmuxPane
    public let summary: String
    public let lastEvent: TmuxHookEvent?

    public init(pane: TmuxPane, summary: String, lastEvent: TmuxHookEvent? = nil) {
        self.pane = pane
        self.summary = summary
        self.lastEvent = lastEvent
    }
}

public struct TmuxHookEvent: Codable, Equatable, Sendable {
    public let event: String
    public let sessionName: String
    public let windowIndex: String
    public let windowId: String
    public let paneIndex: String
    public let paneId: String
    public let paneCurrentCommand: String
    public let paneCurrentPath: String
    public let paneTitle: String
    public let createdAt: Date

    public init(
        event: String,
        sessionName: String,
        windowIndex: String,
        windowId: String,
        paneIndex: String,
        paneId: String,
        paneCurrentCommand: String,
        paneCurrentPath: String,
        paneTitle: String,
        createdAt: Date = Date()
    ) {
        self.event = event
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.windowId = windowId
        self.paneIndex = paneIndex
        self.paneId = paneId
        self.paneCurrentCommand = paneCurrentCommand
        self.paneCurrentPath = paneCurrentPath
        self.paneTitle = paneTitle
        self.createdAt = createdAt
    }
}
