import XCTest
@testable import TmuxPalCore

final class TmuxPalCoreTests: XCTestCase {
    func testDeduplicatesBubblesByPaneIDKeepingFirstObservation() {
        let first = PaneBubble(
            pane: makePane(paneId: "%145", command: "codex", transcriptTail: "first"),
            summary: "first observation"
        )
        let duplicate = PaneBubble(
            pane: makePane(paneId: "%145", command: "codex", transcriptTail: "duplicate"),
            summary: "duplicate observation"
        )

        let bubbles = [first, duplicate].deduplicatedByPaneID()

        XCTAssertEqual(bubbles, [first])
    }

    func testDetectsAiToolsFromTmuxRows() throws {
        let fixture = try String(contentsOfFile: fixturePath("list-panes.txt"), encoding: .utf8)
        let panes = TmuxCollector().parseListPanes(fixture)

        XCTAssertEqual(panes.count, 4)
        XCTAssertEqual(panes.map(\.tool), [.codex, .copilot, .claude, .opencode])
        XCTAssertEqual(panes[0].paneId, "%145")
        XCTAssertTrue(panes[0].currentPath.hasSuffix("sample-agent"))
        for pane in panes {
            XCTAssertEqual(
                pane.status,
                pane.active ? .selected : .idle,
                "tmux panes must not report .running; run state comes from transcript markers"
            )
        }
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
        XCTAssertEqual(pane.status, .running)
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

    func testReusesHerdrTranscriptWithoutExpiryOnlyForNonRunningStatuses() throws {
        let collector = TmuxCollector()
        let idle = try XCTUnwrap(collector.parseHerdrAgentList(herdrAgentList(status: "idle", focused: false)).first)
        let selected = try XCTUnwrap(collector.parseHerdrAgentList(herdrAgentList(status: "idle", focused: true)).first)
        let done = try XCTUnwrap(collector.parseHerdrAgentList(herdrAgentList(status: "done", focused: false)).first)
        let working = try XCTUnwrap(collector.parseHerdrAgentList(herdrAgentList(status: "working", focused: false)).first)
        let tmux = makePane(command: "codex", transcriptTail: "", active: false)

        XCTAssertTrue(TmuxCollector.shouldReuseHerdrTranscriptWithoutExpiry(idle))
        XCTAssertTrue(TmuxCollector.shouldReuseHerdrTranscriptWithoutExpiry(selected))
        XCTAssertTrue(TmuxCollector.shouldReuseHerdrTranscriptWithoutExpiry(done))
        XCTAssertFalse(TmuxCollector.shouldReuseHerdrTranscriptWithoutExpiry(working))
        XCTAssertFalse(TmuxCollector.shouldReuseHerdrTranscriptWithoutExpiry(tmux))
    }

    func testParsesCodexWeeklyAndMonthlyUsageBuckets() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 37, "limit_window_seconds": 604800, "reset_at": 3600},
            "secondary_window": {"used_percent": 12, "limit_window_seconds": 2592000, "reset_at": 7200}
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(CodexUsageParser.snapshot(from: payload, observedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 63)
        XCTAssertEqual(snapshot.monthly?.remainingPercent, 88)
        let weekly = try XCTUnwrap(snapshot.weekly)
        let weeklyPace = try XCTUnwrap(weekly.paceRemainingPercent(at: snapshot.observedAt))
        XCTAssertEqual(weeklyPace, 3600.0 / 604800.0 * 100.0, accuracy: 0.0001)
    }

    func testParsesCodexWhamUsagePrimaryAndSecondaryWindows() throws {
        let payload = """
        {
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 99,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 8963,
              "reset_at": 1782980523
            },
            "secondary_window": {
              "used_percent": 15,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 595763,
              "reset_at": 1783567323
            }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(CodexUsageParser.snapshot(from: payload, observedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.shortTerm?.label, "5h")
        XCTAssertEqual(snapshot.shortTerm?.remainingPercent, 1)
        XCTAssertEqual(snapshot.weekly?.label, "7d")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 85)
    }

    func testUsagePaceRemainingPercentMovesFromFullToEmptyByReset() {
        let bucket = CodexUsageBucket(
            label: "5h",
            usedPercent: 25,
            windowSeconds: 5 * 60 * 60,
            resetAt: 10_000 + 2.5 * 60 * 60
        )

        XCTAssertEqual(bucket.paceRemainingPercent(at: Date(timeIntervalSince1970: 10_000)), 50)
        XCTAssertEqual(bucket.paceRemainingPercent(at: Date(timeIntervalSince1970: 1_000)), 100)
        XCTAssertEqual(bucket.paceRemainingPercent(at: Date(timeIntervalSince1970: 20_000)), 0)
    }

    func testParsesClaudeStatuslineRateLimitsCache() throws {
        let payload = """
        {
          "rate_limits": {
            "five_hour": {"used_percentage": 24, "resets_at": 1781156400},
            "seven_day": {"used_percentage": 5, "resets_at": 1781553600}
          }
        }
        """.data(using: .utf8)!

        let observedAt = Date(timeIntervalSince1970: 1_781_147_400)
        let snapshot = try XCTUnwrap(ClaudeUsageParser.snapshot(from: payload, observedAt: observedAt))
        let fiveHour = try XCTUnwrap(snapshot.fiveHour)
        XCTAssertEqual(fiveHour.label, "5h")
        XCTAssertEqual(fiveHour.remainingPercent, 76)
        XCTAssertEqual(fiveHour.windowSeconds, 5 * 60 * 60)
        let fiveHourPace = try XCTUnwrap(fiveHour.paceRemainingPercent(at: observedAt))
        XCTAssertEqual(fiveHourPace, 50, accuracy: 0.0001)
        let sevenDay = try XCTUnwrap(snapshot.sevenDay)
        XCTAssertEqual(sevenDay.label, "W")
        XCTAssertEqual(sevenDay.remainingPercent, 95)
        XCTAssertEqual(sevenDay.windowSeconds, 7 * 24 * 60 * 60)
    }

    func testParsesFableModelLimitFromRealUsageFixture() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_786_067_562)
        let data = try modelLimitsCacheData(fetchedAt: fetchedAt)

        let snapshot = try XCTUnwrap(ClaudeModelLimitsParser.snapshot(from: data, now: fetchedAt.addingTimeInterval(1)))

        XCTAssertEqual(snapshot.modelLimits.count, 1)
        XCTAssertEqual(snapshot.modelLimits.first?.displayName, "Fable")
        XCTAssertEqual(snapshot.modelLimits.first?.bucket.usedPercent, 100)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 90)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 80)
    }

    func testRejectsModelLimitsCacheOlderThanOneDay() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_786_067_562)
        let data = try modelLimitsCacheData(fetchedAt: fetchedAt)

        XCTAssertNil(ClaudeModelLimitsParser.snapshot(
            from: data,
            now: fetchedAt.addingTimeInterval(ClaudeModelLimitsParser.maxCacheAge + 1)
        ))
    }

    func testMergesFreshStatuslineUsageBeforeOlderModelLimitsUsage() throws {
        let modelFetchedAt = Date(timeIntervalSince1970: 1_786_067_562)
        let modelLimits = try XCTUnwrap(ClaudeModelLimitsParser.snapshot(
            from: try modelLimitsCacheData(fetchedAt: modelFetchedAt),
            now: modelFetchedAt.addingTimeInterval(1)
        ))
        let statuslineObservedAt = modelFetchedAt.addingTimeInterval(600)
        let statusline = try XCTUnwrap(ClaudeUsageParser.snapshot(
            from: """
            {"rate_limits":{"five_hour":{"used_percentage":22},"seven_day":{"used_percentage":33}}}
            """.data(using: .utf8)!,
            observedAt: statuslineObservedAt,
            source: "statusline-cache"
        ))

        let merged = try XCTUnwrap(ClaudeUsageSnapshot.merged(
            statuslineSnapshot: statusline,
            modelLimitsSnapshot: modelLimits
        ))

        XCTAssertEqual(merged.fiveHour?.usedPercent, 22)
        XCTAssertEqual(merged.sevenDay?.usedPercent, 33)
        XCTAssertEqual(merged.fiveHourObservedAt, statuslineObservedAt)
        XCTAssertEqual(merged.sevenDayObservedAt, statuslineObservedAt)
        XCTAssertEqual(merged.modelLimits.first?.displayName, "Fable")
        XCTAssertEqual(merged.modelLimits.first?.observedAt, modelFetchedAt)
    }

    func testParsesClaudeUtilizationFractionAndIsoResetTimestamp() throws {
        let payload = """
        {
          "rate_limits": {
            "five_hour": {"utilization": 0.4, "resets_at": "1970-01-01T05:00:00Z"},
            "seven_day": {"utilization": 62}
          }
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(ClaudeUsageParser.snapshot(from: payload, observedAt: Date(timeIntervalSince1970: 0)))
        let fiveHour = try XCTUnwrap(snapshot.fiveHour)
        XCTAssertEqual(fiveHour.usedPercent, 40)
        XCTAssertEqual(fiveHour.resetAt, 5 * 60 * 60)
        XCTAssertEqual(fiveHour.paceRemainingPercent(at: snapshot.observedAt), 100)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 62)
        XCTAssertNil(snapshot.sevenDay?.resetAt)
    }

    func testParsesClaudeLiveUsageAliases() throws {
        let payload = """
        {
          "fiveHour": {"used_percent": 31, "reset_at": 18000},
          "weekly": {"percentage": 44}
        }
        """.data(using: .utf8)!

        let snapshot = try XCTUnwrap(ClaudeUsageParser.snapshot(from: payload, observedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.fiveHour?.label, "5h")
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 31)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, 18000)
        XCTAssertEqual(snapshot.sevenDay?.label, "W")
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 44)
    }

    func testClaudeUsageParserReturnsNilWithoutBuckets() {
        let payload = "{\"rate_limits\": {}}".data(using: .utf8)!
        XCTAssertNil(ClaudeUsageParser.snapshot(from: payload))
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

    func testClassifiesHerdrWorkingFocusedAgentAsRunningWithoutTranscriptMarker() {
        let pane = TmuxPane(
            sessionName: TmuxCollector.herdrSessionName,
            windowIndex: "w1",
            windowId: "w1:1",
            windowName: "w1",
            paneIndex: "w1-1",
            paneId: "w1-1",
            panePid: "",
            paneTty: "",
            currentCommand: "codex",
            currentPath: "/workspace/sample-repo",
            active: true,
            title: "working",
            commandLine: "codex",
            transcriptExcerpt: "Review current diff",
            transcriptTail: "Review current diff",
            tool: .codex,
            status: .running
        )

        XCTAssertEqual(
            BubbleRunClassifier().classify(PaneBubble(pane: pane, summary: "sample-repo\nReview current diff")),
            .running
        )
    }

    func testClassifiesHerdrIdleAsCompleteDespiteRunningTranscript() throws {
        let pane = try XCTUnwrap(
            TmuxCollector().parseHerdrAgentList(herdrAgentList(status: "idle", focused: false)).first
        ).withTranscript(excerpt: "Run tests", tail: "• Working (43s · esc to interrupt)")
        let selectedPane = try XCTUnwrap(
            TmuxCollector().parseHerdrAgentList(herdrAgentList(status: "idle", focused: true)).first
        ).withTranscript(excerpt: "Run tests", tail: "• Working (43s · esc to interrupt)")

        XCTAssertEqual(BubbleRunClassifier().classify(PaneBubble(pane: pane, summary: "Run tests")), .complete)
        XCTAssertEqual(BubbleRunClassifier().classify(PaneBubble(pane: selectedPane, summary: "Run tests")), .complete)
    }

    func testClassifiesHerdrDoneAsComplete() throws {
        let pane = try XCTUnwrap(
            TmuxCollector().parseHerdrAgentList(herdrAgentList(status: "done", focused: false)).first
        ).withTranscript(excerpt: "Run tests", tail: "• Working (43s · esc to interrupt)")

        XCTAssertEqual(pane.status, .idle)
        XCTAssertEqual(BubbleRunClassifier().classify(PaneBubble(pane: pane, summary: "Run tests")), .complete)
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
        let collector = TmuxCollector(tmuxPath: "tmux", tmuxSocketPath: "/tmp/test", runner: runner, herdrPath: "herdr")
        let pane = makePane(
            sessionName: TmuxCollector.herdrSessionName,
            paneId: "w6523c5b0eb8895-1",
            command: "codex",
            transcriptTail: ""
        )

        try collector.focus(pane)

        XCTAssertTrue(runner.executables.contains("herdr"))
        XCTAssertTrue(runner.commands.contains(["agent", "focus", "w6523c5b0eb8895-1"]))
        XCTAssertFalse(runner.commands.contains { $0.contains("select-pane") })
    }

    func testCollectUsesInjectedHerdrExecutable() throws {
        let output = """
        {"id":"cli:agent:list","result":{"agents":[{"agent":"codex","agent_status":"working","cwd":"/workspace/tmuxpal","focused":true,"pane_id":"w1-1","revision":0,"tab_id":"w1:1","terminal_id":"term_1","workspace_id":"w1"}],"type":"agent_list"}}
        """
        let runner = RecordingRunner(outputs: [
            "list-panes": "",
            "agent": output
        ])
        let collector = TmuxCollector(
            tmuxPath: "tmux",
            tmuxSocketPath: "/tmp/test",
            runner: runner,
            herdrPath: "/Users/example/.local/bin/herdr"
        )

        let panes = try collector.collect()

        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].sessionName, TmuxCollector.herdrSessionName)
        XCTAssertTrue(runner.executables.contains("/Users/example/.local/bin/herdr"))
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

    private func modelLimitsCacheData(fetchedAt: Date) throws -> Data {
        let sampleData = try Data(contentsOf: URL(fileURLWithPath: fixturePath("usage-sample.json")))
        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: sampleData) as? [String: Any])
        let rateLimits = try XCTUnwrap(sample["rate_limits"] as? [String: Any])
        let limits = try XCTUnwrap(rateLimits["limits"] as? [[String: Any]])
        XCTAssertTrue(limits.contains { ($0["kind"] as? String) == "session" })
        XCTAssertTrue(limits.contains { ($0["kind"] as? String) == "weekly_all" })
        let scopedLimit = try XCTUnwrap(limits.first { ($0["kind"] as? String) == "weekly_scoped" })
        let displayName = try XCTUnwrap(
            ((scopedLimit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        )
        let usedPercentage = try XCTUnwrap(scopedLimit["percent"] as? Int)
        let resetAt = try XCTUnwrap(epochSeconds(from: scopedLimit["resets_at"] as? String))
        let fiveHour = try XCTUnwrap(rateLimits["five_hour"] as? [String: Any])
        let sevenDay = try XCTUnwrap(rateLimits["seven_day"] as? [String: Any])

        let cache: [String: Any] = [
            "fetched_at": Int(fetchedAt.timeIntervalSince1970),
            "source": "get_usage",
            "model_limits": [[
                "display_name": displayName,
                "used_percentage": usedPercentage,
                "resets_at": resetAt
            ]],
            "rate_limits": [
                "five_hour": [
                    "used_percentage": try XCTUnwrap(fiveHour["utilization"] as? Int),
                    "resets_at": try XCTUnwrap(epochSeconds(from: fiveHour["resets_at"] as? String))
                ],
                "seven_day": [
                    "used_percentage": try XCTUnwrap(sevenDay["utilization"] as? Int),
                    "resets_at": try XCTUnwrap(epochSeconds(from: sevenDay["resets_at"] as? String))
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: cache)
    }

    private func epochSeconds(from text: String?) -> Int? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text).map { Int($0.timeIntervalSince1970) }
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

    private func herdrAgentList(status: String, focused: Bool) -> String {
        """
        {"id":"cli:agent:list","result":{"agents":[{"agent":"codex","agent_status":"\(status)","cwd":"/workspace/tmuxpal","focused":\(focused),"pane_id":"w1-1","revision":0,"tab_id":"w1:1","terminal_id":"term_1","workspace_id":"w1"}],"type":"agent_list"}}
        """
    }

}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let outputs: [String: String]
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []
    private var recordedExecutables: [String] = []

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    var executables: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedExecutables
    }

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        lock.lock()
        recordedExecutables.append(executable)
        recordedCommands.append(arguments)
        lock.unlock()
        for (needle, output) in outputs where arguments.contains(needle) {
            return output
        }
        return ""
    }
}
