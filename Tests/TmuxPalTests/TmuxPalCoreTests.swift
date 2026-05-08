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
        transcriptTail: String
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
            active: true,
            title: "repo",
            commandLine: command,
            transcriptExcerpt: transcriptTail,
            transcriptTail: transcriptTail,
            tool: .codex,
            status: .selected
        )
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
