import XCTest
@testable import TmuxPalCore

final class TmuxPalCoreTests: XCTestCase {
    func testDetectsAiToolsFromTmuxRows() throws {
        let fixture = try String(contentsOfFile: fixturePath("list-panes.txt"), encoding: .utf8)
        let panes = TmuxCollector().parseListPanes(fixture)

        XCTAssertEqual(panes.count, 4)
        XCTAssertEqual(panes.map(\.tool), [.codex, .copilot, .claude, .opencode])
        XCTAssertEqual(panes[0].paneId, "%145")
        XCTAssertTrue(panes[0].currentPath.hasSuffix("sample-agent"))
    }

    func testNodeBackedCodexDetectionUsesCommandLineOverride() {
        let separator = TmuxCollector.fieldSeparator
        let row = [
            "0",
            "1",
            "@1",
            "sample-agent",
            "1",
            "%145",
            "12345",
            "/dev/ttys001",
            "node",
            "/workspace/sample-agent",
            "0",
            "sample-agent"
        ].joined(separator: separator)

        let pane = TmuxCollector().parseLine(
            row,
            commandLineOverride: "node /usr/local/bin/codex resume --last"
        )

        XCTAssertEqual(pane?.tool, .codex)
    }

    func testDetectsHerdrCodexAgents() throws {
        let output = """
        {"id":"cli:agent:list","result":{"agents":[{"agent":"codex","agent_status":"working","cwd":"/workspace/tmuxpal","focused":true,"pane_id":"w6523c5b0eb8895-1","revision":0,"tab_id":"w6523c5b0eb8895:1","terminal_id":"term_6523c5b0eb885a","workspace_id":"w6523c5b0eb8895"}],"type":"agent_list"}}
        """

        let panes = TmuxCollector().parseHerdrAgentList(output)

        let pane = try XCTUnwrap(panes.first)
        XCTAssertEqual(pane.tool, .codex)
        XCTAssertEqual(pane.sessionName, TmuxCollector.herdrSessionName)
        XCTAssertEqual(pane.paneId, "w6523c5b0eb8895-1")
        XCTAssertEqual(pane.currentPath, "/workspace/tmuxpal")
        XCTAssertEqual(pane.status, .selected)
    }

    func testHerdrPaneListIgnoresNonAgentPanes() {
        let output = """
        {"id":"cli:pane:list","result":{"panes":[{"agent":"codex","agent_status":"idle","cwd":"/workspace/agent","focused":false,"pane_id":"w1-1","revision":0,"tab_id":"w1:1","terminal_id":"term_1","workspace_id":"w1"},{"agent_status":"unknown","cwd":"/workspace/shell","focused":false,"pane_id":"w1-2","revision":0,"tab_id":"w1:1","terminal_id":"term_2","workspace_id":"w1"}],"type":"pane_list"}}
        """

        let panes = TmuxCollector().parseHerdrPaneList(output)

        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].paneId, "w1-1")
        XCTAssertEqual(panes[0].status, .idle)
    }

    func testParsesCodexWeeklyAndMonthlyUsageBuckets() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 37, "limit_window_seconds": 604800},
            "secondary_window": {"used_percent": 12, "limit_window_seconds": 2592000}
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(CodexUsageParser.snapshot(from: payload))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 63)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 88)
    }

    func testExtractsTextFromHerdrAgentReadJsonEnvelope() {
        let output = #"{"id":"cli:agent:read","result":{"read":{"format":"text","pane_id":"w1-1","revision":0,"source":"recent_unwrapped","tab_id":"w1:1","text":"Review current diff\nRun swift test"}}}"#

        XCTAssertEqual(TmuxCollector.herdrReadText(from: output), "Review current diff\nRun swift test")
    }

    func testSummarizerDoesNotShowHerdrCliJsonEnvelope() {
        let pane = makePane(
            sessionName: TmuxCollector.herdrSessionName,
            paneId: "w1-1",
            command: "codex",
            transcriptTail: #"{"id":"cli:agent:read","result":{"read":{"text":"ignored"}}}"#,
            active: false
        )

        let summary = BubbleSummarizer().summarize(pane, event: nil)

        XCTAssertFalse(summary.contains(#""id":"cli:agent:read""#))
        XCTAssertEqual(summary, "sample-repo\nrepo")
    }

    func testSummarizesActiveAndTitledPanes() throws {
        let fixture = try String(contentsOfFile: fixturePath("list-panes.txt"), encoding: .utf8)
        let panes = TmuxCollector().parseListPanes(fixture)
        let copilot = try XCTUnwrap(panes.first { $0.tool == .copilot })
        let summary = BubbleSummarizer().summarize(copilot, event: nil)

        XCTAssertFalse(summary.contains("Copilot"))
        XCTAssertFalse(summary.contains("2.1"))
        XCTAssertTrue(summary.contains("sample-repo"))
        XCTAssertTrue(summary.contains("Sample build task"))
    }

    func testHookEventStoreReadsJsonLines() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let eventsURL = tempDir.appendingPathComponent("events.jsonl")
        let payload = #"{"event":"pane-exited","sessionName":"0","windowIndex":"2","windowId":"@2","paneIndex":"1","paneId":"%130","paneCurrentCommand":"copilot","paneCurrentPath":"/workspace/sample-repo","paneTitle":"done","createdAt":"2026-05-07T00:00:00Z"}"#
        try payload.write(to: eventsURL, atomically: true, encoding: .utf8)

        let events = HookEventStore(eventsURL: eventsURL).readRecent()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].paneId, "%130")
        XCTAssertEqual(events[0].event, "pane-exited")
    }

    func testClassifiesWorkingAfterOlderCompletedAsRunning() throws {
        let transcript = try String(contentsOfFile: fixturePath("codex-working-after-completed.txt"), encoding: .utf8)
        let bubble = PaneBubble(
            pane: makePane(command: "node", transcriptTail: transcript),
            summary: "sample-repo\nRun /review on my current changes"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .running)
    }

    func testClassifiesCodexPromptAsComplete() {
        let transcript = """
        ─ Worked for 1m 30s ──────────────────

        › Write tests for @filename
        """
        let bubble = PaneBubble(
            pane: makePane(command: "node", transcriptTail: transcript),
            summary: "sample-agent\n- Review current implementation"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .complete)
    }

    func testClassifiesNoActiveAgentsAsComplete() {
        let transcript = "| Next refresh: 5s | No active agents |-- Backoff queue"
        let bubble = PaneBubble(
            pane: makePane(command: "beam.smp", transcriptTail: transcript),
            summary: "elixir\n\(transcript)"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .complete)
    }

    func testClassifiesCopilotIdlePromptWithHistoryAsComplete() {
        let transcript = """
        ● Inspect current implementation (shell)
          │ rg -n "sample" Sources Tests
          └ 12 lines...

        ~/workspace/sample [main]
        ───────────────────────────────────────
        ❯
        """
        let bubble = PaneBubble(
            pane: makePane(command: "copilot", transcriptTail: transcript, tool: .copilot),
            summary: "sample\nInspect current implementation"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .complete)
    }

    func testClassifiesCopilotEscToCancelAsRunning() {
        let transcript = """
        ● Task complete
          └ Previous task is done.

        ● Inspecting workflow run (Esc to cancel · 612 B)

        ~/workspace/sample [main]
        ───────────────────────────────────────
        ❯
        """
        let bubble = PaneBubble(
            pane: makePane(command: "copilot", transcriptTail: transcript, tool: .copilot),
            summary: "sample\nInspecting workflow run"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .running)
    }

    func testClassifiesCopilotActiveTaskAsRunningDespiteCompletedCommandOutput() {
        let transcript = """
        ● Check workflow status (shell)
          │ gh run list --json status,conclusion --limit 2
          └ [{"status":"completed","conclusion":"success"}]

        ● Continue follow-up work (shell)
          │ ./scripts/verify-release
          └ running...

        ~/workspace/sample [main]
        ───────────────────────────────────────
        ❯
        """
        let bubble = PaneBubble(
            pane: makePane(command: "copilot", transcriptTail: transcript, tool: .copilot),
            summary: "sample\nWorkflow status included completed rows"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .running)
    }

    func testClassifiesShellBackedDetectedAgentAsRunning() {
        let transcript = """
        ● Execute generated command (shell)
          │ npm test
          └ running...
        """
        let bubble = PaneBubble(
            pane: makePane(command: "zsh", transcriptTail: transcript, tool: .copilot),
            summary: "sample\nExecute generated command"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .running)
    }

    func testClassifiesCopilotTaskCompleteAsComplete() {
        let transcript = """
        ● Verify result (shell)
          └ 4 lines...

        ● Task complete
          └ The requested update is done.

        ~/workspace/sample [main]
        ───────────────────────────────────────
        ❯
        """
        let bubble = PaneBubble(
            pane: makePane(command: "copilot", transcriptTail: transcript, tool: .copilot),
            summary: "sample\nTask complete"
        )

        XCTAssertEqual(BubbleRunClassifier().classify(bubble), .complete)
    }

    func testCollectRefreshesTranscriptWhenCacheTTLExpires() throws {
        let row = tmuxRow(command: "copilot", title: "Sample task")
        let runner = RecordingRunner(outputs: [
            "list-panes": row,
            "capture-pane": "● Execute generated command (shell)\n  └ running...\n"
        ])
        let collector = TmuxCollector(
            tmuxPath: "tmux",
            tmuxSocketPath: "/tmp/test",
            runner: runner,
            transcriptCacheTTL: 0,
            activeTranscriptCacheTTL: 0
        )

        _ = try collector.collect()
        _ = try collector.collect()

        XCTAssertEqual(runner.commands.filter { $0.contains("capture-pane") }.count, 2)
    }

    func testCollectReusesTranscriptForInactivePanesWithinCacheTTL() throws {
        let row = tmuxRow(command: "copilot", title: "Sample task", active: false)
        let runner = RecordingRunner(outputs: [
            "list-panes": row,
            "capture-pane": "● Execute generated command (shell)\n  └ running...\n"
        ])
        let collector = TmuxCollector(
            tmuxPath: "tmux",
            tmuxSocketPath: "/tmp/test",
            runner: runner,
            transcriptCacheTTL: 60,
            activeTranscriptCacheTTL: 0
        )

        _ = try collector.collect()
        _ = try collector.collect()

        XCTAssertEqual(runner.commands.filter { $0.contains("capture-pane") }.count, 1)
    }

    func testBadgeCountsCompletedAwaitingBubbles() {
        let completedPrompt = PaneBubble(
            pane: makePane(command: "node", transcriptTail: "\n› Ready for next instruction"),
            summary: "sample-agent\nWaiting for instructions"
        )
        let stoppedAgent = PaneBubble(
            pane: makePane(command: "beam.smp", transcriptTail: "No active agents"),
            summary: "elixir\nNo active agents"
        )
        let running = PaneBubble(
            pane: makePane(command: "node", transcriptTail: "• Working (43s · esc to interrupt)"),
            summary: "sample-agent\nRun tests"
        )

        XCTAssertEqual(
            BubbleBadgeCounter().completedAwaitingCount(in: [completedPrompt, stoppedAgent, running]),
            2
        )
    }

    func testParsesTmuxClients() {
        let output = [
            "/dev/ttys000|#|0|#|1|#|1",
            "/dev/ttys003|#|other-session|#|1|#|1"
        ].joined(separator: "\n")

        let clients = TmuxCollector(tmuxSocketPath: "/tmp/test").parseListClients(output)

        XCTAssertEqual(clients, [
            TmuxClient(name: "/dev/ttys000", sessionName: "0", windowIndex: "1", paneIndex: "1"),
            TmuxClient(name: "/dev/ttys003", sessionName: "other-session", windowIndex: "1", paneIndex: "1")
        ])
    }

    func testFocusSwitchesClientForDifferentSessionPane() throws {
        let runner = RecordingRunner(outputs: [
            "list-clients": "/dev/ttys000|#|0|#|1|#|1\n"
        ])
        let collector = TmuxCollector(tmuxPath: "tmux", tmuxSocketPath: "/tmp/test", runner: runner)
        let pane = makePane(
            sessionName: "other-session",
            windowIndex: "1",
            paneIndex: "1",
            paneId: "%93",
            command: "beam.smp",
            transcriptTail: ""
        )

        try collector.focus(pane)

        XCTAssertTrue(runner.commands.contains { $0.suffix(3) == ["list-clients", "-F", "#{client_name}|#|#{session_name}|#|#{window_index}|#|#{pane_index}"] })
        XCTAssertTrue(runner.commands.contains { $0.suffix(5) == ["switch-client", "-c", "/dev/ttys000", "-t", "other-session:1.1"] })
        XCTAssertTrue(runner.commands.contains { $0.suffix(3) == ["select-pane", "-t", "%93"] })
        XCTAssertFalse(runner.commands.contains { $0.contains("select-window") })
    }

    func testFocusUsesHerdrForHerdrPane() throws {
        let runner = RecordingRunner(outputs: [:])
        let collector = TmuxCollector(tmuxPath: "tmux", tmuxSocketPath: "/tmp/test", runner: runner)
        let pane = makePane(
            sessionName: TmuxCollector.herdrSessionName,
            paneId: "w6523c5b0eb8895-1",
            command: "codex",
            transcriptTail: ""
        )

        try collector.focus(pane)

        XCTAssertTrue(runner.commands.contains(["herdr", "agent", "focus", "w6523c5b0eb8895-1"]))
        XCTAssertFalse(runner.commands.contains { $0.contains("select-pane") })
    }

    func testCollectDoesNotInspectPlainShellPaneProcessList() throws {
        let row = tmuxRow(command: "zsh", title: "shell")
        let runner = RecordingRunner(outputs: [
            "list-panes": row
        ])
        let collector = TmuxCollector(tmuxPath: "tmux", tmuxSocketPath: "/tmp/test", runner: runner)

        _ = try collector.collect()

        XCTAssertFalse(runner.commands.contains { $0.first == "-o" })
    }

    func testCollectCachesNegativeProcessLineInspection() throws {
        let row = tmuxRow(command: "node", title: "vite dev server")
        let runner = RecordingRunner(outputs: [
            "list-panes": row
        ])
        let collector = TmuxCollector(tmuxPath: "tmux", tmuxSocketPath: "/tmp/test", runner: runner)

        _ = try collector.collect()
        _ = try collector.collect()

        XCTAssertEqual(runner.commands.filter { $0.first == "-o" }.count, 1)
    }

    private func fixturePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    private func makePane(
        sessionName: String = "0",
        windowIndex: String = "1",
        paneIndex: String = "1",
        paneId: String = "%1",
        command: String,
        transcriptTail: String,
        tool: AiTool = .codex,
        active: Bool = true
    ) -> TmuxPane {
        TmuxPane(
            sessionName: sessionName,
            windowIndex: windowIndex,
            windowId: "@1",
            windowName: "repo",
            paneIndex: paneIndex,
            paneId: paneId,
            panePid: "123",
            paneTty: "/dev/ttys001",
            currentCommand: command,
            currentPath: "/workspace/sample-repo",
            active: active,
            title: "repo",
            commandLine: command,
            transcriptExcerpt: transcriptTail,
            transcriptTail: transcriptTail,
            tool: tool,
            status: active ? .selected : .idle
        )
    }

    private func tmuxRow(command: String, title: String, active: Bool = false) -> String {
        [
            "0",
            "1",
            "@1",
            "sample-agent",
            "1",
            "%145",
            "12345",
            "/dev/ttys001",
            command,
            "/workspace/sample-agent",
            active ? "1" : "0",
            title
        ].joined(separator: TmuxCollector.fieldSeparator)
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let outputs: [String: String]
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        lock.lock()
        recordedCommands.append(arguments)
        lock.unlock()
        for (needle, output) in outputs where arguments.contains(needle) {
            return output
        }
        return ""
    }
}
