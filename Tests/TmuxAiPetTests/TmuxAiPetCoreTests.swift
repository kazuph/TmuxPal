import XCTest
@testable import TmuxAiPetCore

final class TmuxAiPetCoreTests: XCTestCase {
    func testDetectsAiToolsFromTmuxRows() throws {
        let fixture = try String(contentsOfFile: fixturePath("list-panes.txt"), encoding: .utf8)
        let panes = TmuxCollector().parseListPanes(fixture)

        XCTAssertEqual(panes.count, 4)
        XCTAssertEqual(panes.map(\.tool), [.codex, .copilot, .claude, .opencode])
        XCTAssertEqual(panes[0].paneId, "%145")
        XCTAssertTrue(panes[0].currentPath.hasSuffix("hermes-agent"))
    }

    func testNodeBackedCodexDetectionUsesCommandLineOverride() {
        let separator = TmuxCollector.fieldSeparator
        let row = [
            "0",
            "1",
            "@1",
            "hermes-agent",
            "1",
            "%145",
            "12345",
            "/dev/ttys001",
            "node",
            "/Users/kazuph/src/github.com/nousresearch/hermes-agent",
            "0",
            "hermes-agent"
        ].joined(separator: separator)

        let pane = TmuxCollector().parseLine(
            row,
            commandLineOverride: "node /Users/kazuph/.local/share/mise/installs/node/22.21.1/bin/codex resume --last"
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
        XCTAssertTrue(summary.contains("homura"))
        XCTAssertTrue(summary.contains("Mount R2 In Ruby Worker"))
    }

    func testHookEventStoreReadsJsonLines() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let eventsURL = tempDir.appendingPathComponent("events.jsonl")
        let payload = #"{"event":"pane-exited","sessionName":"0","windowIndex":"2","windowId":"@2","paneIndex":"1","paneId":"%130","paneCurrentCommand":"copilot","paneCurrentPath":"/tmp/repo","paneTitle":"done","createdAt":"2026-05-07T00:00:00Z"}"#
        try payload.write(to: eventsURL, atomically: true, encoding: .utf8)

        let events = HookEventStore(eventsURL: eventsURL).readRecent()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].paneId, "%130")
        XCTAssertEqual(events[0].event, "pane-exited")
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
}
