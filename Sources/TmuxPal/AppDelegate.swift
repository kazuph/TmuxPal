import AppKit
import Foundation
import ServiceManagement
import TmuxPalCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayController?
    private var appServerManager: AppServerManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.shouldContinueLaunching() else {
            DebugLog.write("app exiting because another instance is already running")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        try? AppSupport.ensureSupportDirectory()
        DebugLog.write("app launched")

        let overlayController = OverlayController()
        self.overlayController = overlayController
        overlayController.show()

        let appServerManager = AppServerManager()
        self.appServerManager = appServerManager
        appServerManager.startIfAvailable()
        TmuxHookInstaller.installHooks()

        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("app terminating")
        appServerManager?.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TmuxPal"
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "表示/非表示", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "再読み込み", action: #selector(reloadOverlay), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(palSelectionMenuItem())
        menu.addItem(palSizeMenuItem())
        menu.addItem(NSMenuItem(title: "デフォルトに戻す", action: #selector(useDefaultPal), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "tmux hooks を再インストール", action: #selector(reinstallTmuxHooks), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "tmux hooks を削除", action: #selector(uninstallTmuxHooks), keyEquivalent: ""))
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func palSelectionMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "パルを選択", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let palDirectories = PalSettings.discoveredPalDirectories()

        if palDirectories.isEmpty {
            submenu.addItem(NSMenuItem(title: "ファイルから選択...", action: #selector(selectPalFromFile), keyEquivalent: ""))
        } else {
            for directory in palDirectories {
                let item = NSMenuItem(
                    title: PalSettings.displayName(forPalDirectory: directory),
                    action: #selector(selectDiscoveredPal(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = directory
                item.state = PalSettings.selectedPalDirectory?.standardizedFileURL == directory.standardizedFileURL ? .on : .off
                submenu.addItem(item)
            }
        }

        rootItem.submenu = submenu
        return rootItem
    }

    private func palSizeMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "サイズ", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for size in PalDisplaySize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(selectPalSize(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            item.state = PalSettings.displaySize == size ? .on : .off
            submenu.addItem(item)
        }

        rootItem.submenu = submenu
        return rootItem
    }

    @objc private func toggleOverlay() {
        overlayController?.toggle()
    }

    @objc private func reloadOverlay() {
        overlayController?.reloadNow()
    }

    @objc private func selectDiscoveredPal(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL else {
            return
        }
        PalSettings.selectedPalDirectory = directory
        overlayController?.reloadPalAssets()
        rebuildStatusMenu()
    }

    @objc private func selectPalFromFile() {
        let panel = NSOpenPanel()
        panel.title = "パルを選択"
        panel.message = "pal.json を含むフォルダ、または pal.json を選択してください。"
        panel.directoryURL = PalSettings.defaultPalPickerDirectory()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard PalSettings.metadataURL(in: directory) != nil else {
            DebugLog.write("pal selection ignored: metadata not found in \(directory.path)")
            return
        }
        PalSettings.selectedPalDirectory = directory
        overlayController?.reloadPalAssets()
        rebuildStatusMenu()
    }

    @objc private func useDefaultPal() {
        PalSettings.selectedPalDirectory = nil
        overlayController?.reloadPalAssets()
        rebuildStatusMenu()
    }

    @objc private func selectPalSize(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let size = PalDisplaySize(rawValue: rawValue) else {
            return
        }
        PalSettings.displaySize = size
        overlayController?.setPalDisplaySize(size)
        rebuildStatusMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
            rebuildStatusMenu()
        } catch {
            DebugLog.write("login item toggle failed: \(error.localizedDescription)")
        }
    }

    @objc private func reinstallTmuxHooks() {
        TmuxHookInstaller.installHooks()
    }

    @objc private func uninstallTmuxHooks() {
        TmuxHookInstaller.uninstallHooks()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum SingleInstanceGuard {
    static func shouldContinueLaunching() -> Bool {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppSupport.bundleIdentifier
        return !NSWorkspace.shared.runningApplications.contains { app in
            app.processIdentifier != currentPid
                && app.bundleIdentifier == bundleIdentifier
                && app.isTerminated == false
        }
    }
}

enum PalSettings {
    private static let selectedPalDirectoryKey = "selectedPalDirectory"
    private static let displaySizeKey = "palDisplaySize"
    private static let userCharacterRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/tmuxpal/characters")
    private static let legacyCharacterRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
        .appendingPathComponent(["pe", "ts"].joined())

    static var selectedPalDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: selectedPalDirectoryKey), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: selectedPalDirectoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedPalDirectoryKey)
            }
        }
    }

    static func assetConfig() -> PalAssetConfig {
        if let selected = selectedPalDirectory,
           let metadataURL = metadataURL(in: selected) {
            return PalAssetConfig(metadataURL: metadataURL)
        }
        if let bundled = bundledDokochanDirectory() {
            return PalAssetConfig(metadataURL: bundled.appendingPathComponent("pal.json"))
        }
        return PalAssetConfig()
    }

    static var displaySize: PalDisplaySize {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: displaySizeKey),
                  let size = PalDisplaySize(rawValue: rawValue) else {
                return .small
            }
            return size
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: displaySizeKey)
        }
    }

    static func discoveredPalDirectories() -> [URL] {
        let roots = [userCharacterRoot, legacyCharacterRoot]
        let children = roots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        var seen: Set<String> = []
        return children
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && metadataURL(in: url) != nil
                    && seen.insert(url.standardizedFileURL.path).inserted
            }
            .sorted { displayName(forPalDirectory: $0).localizedCaseInsensitiveCompare(displayName(forPalDirectory: $1)) == .orderedAscending }
    }

    static func defaultPalPickerDirectory() -> URL {
        if FileManager.default.fileExists(atPath: userCharacterRoot.path) {
            return userCharacterRoot
        }
        if FileManager.default.fileExists(atPath: legacyCharacterRoot.path) {
            return legacyCharacterRoot
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func displayName(forPalDirectory directory: URL) -> String {
        if let metadataURL = metadataURL(in: directory),
           let data = try? Data(contentsOf: metadataURL),
           let request = try? JSONDecoder().decode(PalRequest.self, from: data) {
            return request.displayName
        }
        return directory.lastPathComponent
    }

    static func metadataURL(in directory: URL) -> URL? {
        for name in ["pal.json", ["pe", "t"].joined() + ".json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func bundledDokochanDirectory() -> URL? {
        let subdirectory = "Characters/dokochan"
        if let url = Bundle.main.url(forResource: "pal", withExtension: "json", subdirectory: subdirectory) {
            return url.deletingLastPathComponent()
        }
        if let url = Bundle.module.url(forResource: "pal", withExtension: "json", subdirectory: subdirectory) {
            return url.deletingLastPathComponent()
        }
        return nil
    }
}

enum PalDisplaySize: String, CaseIterable {
    case small
    case medium
    case large

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 1.2
        case .medium: return 2.4
        case .large: return 3.6
        }
    }
}

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum TmuxHookInstaller {
    private static let hookNames = [
        "after-new-window",
        "after-split-window",
        "after-select-window",
        "after-select-pane",
        "pane-exited",
        "pane-died"
    ]

    static func installHooks() {
        guard let tmux = tmuxExecutable() else {
            DebugLog.write("tmux hook install skipped: tmux executable not found")
            return
        }
        guard let script = stableHookScriptURL() else {
            DebugLog.write("tmux hook install skipped: tmuxpal-hook.sh not found")
            return
        }

        let slot = hookSlot()
        for hookName in hookNames {
            _ = run(tmux, arguments: ["set-hook", "-gu", "\(hookName)[\(slot)]"])
            let command = "run-shell -b '\"\(script.path)\" \"\(hookName)\" \"#{session_name}\" \"#{window_index}\" \"#{window_id}\" \"#{pane_index}\" \"#{pane_id}\" \"#{pane_current_command}\" \"#{pane_current_path}\" \"#{pane_title}\"'"
            let result = run(tmux, arguments: ["set-hook", "-g", "\(hookName)[\(slot)]", command])
            if result != 0 {
                DebugLog.write("tmux hook install failed: \(hookName) exit=\(result)")
            }
        }
        DebugLog.write("tmux hooks installed slot=\(slot) script=\(script.path)")
    }

    static func uninstallHooks() {
        guard let tmux = tmuxExecutable() else {
            DebugLog.write("tmux hook uninstall skipped: tmux executable not found")
            return
        }
        let slot = hookSlot()
        for hookName in hookNames {
            _ = run(tmux, arguments: ["set-hook", "-gu", "\(hookName)[\(slot)]"])
        }
        DebugLog.write("tmux hooks removed slot=\(slot)")
    }

    private static func hookSlot() -> Int {
        Int(ProcessInfo.processInfo.environment["TMUXPAL_HOOK_SLOT"] ?? "") ?? 900
    }

    private static func stableHookScriptURL() -> URL? {
        guard let source = hookScriptSourceURL() else {
            return nil
        }
        let destination = AppSupport.supportDirectory.appendingPathComponent("tmuxpal-hook.sh")
        do {
            try AppSupport.ensureSupportDirectory()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            makeExecutableIfNeeded(destination)
            return destination
        } catch {
            DebugLog.write("tmux hook script copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func hookScriptSourceURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "tmuxpal-hook", withExtension: "sh") {
            return bundled
        }
        if let module = Bundle.module.url(forResource: "tmuxpal-hook", withExtension: "sh") {
            return module
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let developmentScript = currentDirectory.appendingPathComponent("Scripts/tmuxpal-hook.sh")
        if FileManager.default.fileExists(atPath: developmentScript.path) {
            return developmentScript
        }
        return nil
    }

    private static func tmuxExecutable() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["TMUX_BIN"], FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }

        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "command -v tmux"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func makeExecutableIfNeeded(_ url: URL) {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else {
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private static func run(_ executable: URL, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            DebugLog.write("tmux command failed: \(error.localizedDescription)")
            return -1
        }
    }
}

@MainActor
final class OverlayController {
    private let window: OverlayPanel
    private let overlayView: OverlayView
    private let collector = TmuxCollector()
    private let eventStore = HookEventStore()
    private let summarizer = BubbleSummarizer()
    private var timer: Timer?
    private var lastLoggedBubbleCount: Int?
    private var isUpdating = false
    private var palAnchorScreenCenter: CGPoint?

    init() {
        overlayView = OverlayView(palAssetConfig: PalSettings.assetConfig())
        window = OverlayPanel(
            contentRect: OverlayController.savedFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = overlayView
        window.ignoresMouseEvents = false
        DebugLog.write("overlay initialized frame=\(NSStringFromRect(window.frame))")

        overlayView.onDrag = { [weak self] screenPoint, grabOffset, horizontalDelta in
            self?.moveWindow(toScreenPoint: screenPoint, grabOffset: grabOffset, horizontalDelta: horizontalDelta)
        }
        overlayView.onClickPane = { [weak self] pane in
            do {
                try self?.collector.focus(pane)
                DebugLog.write("focused pane=\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex) \(pane.paneId)")
            } catch {
                DebugLog.write("focus failed pane=\(pane.paneId): \(error.localizedDescription)")
            }
            TerminalActivator.activatePreferredTerminal()
        }
        overlayView.onCollapseChanged = { [weak self] in
            self?.fitWindow()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        clampToVisibleScreen()
        palAnchorScreenCenter = palScreenCenter()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        DebugLog.write("overlay shown frame=\(NSStringFromRect(window.frame))")
        startTimer()
    }

    func toggle() {
        window.isVisible ? window.orderOut(nil) : show()
    }

    func reloadNow() {
        updatePanes()
        reloadPalAssets()
    }

    func reloadPalAssets() {
        overlayView.reloadPalAssets(config: PalSettings.assetConfig())
    }

    func setPalDisplaySize(_ size: PalDisplaySize) {
        let palCenter = palScreenCenter()
        overlayView.setPalScale(size.scale)
        fitWindow(keepingPalCenter: palCenter)
        saveFrame()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePanes()
            }
        }
        updatePanes()
    }

    private func updatePanes() {
        guard !isUpdating else { return }
        isUpdating = true
        let collector = collector
        let eventStore = eventStore
        let summarizer = summarizer

        Task {
            let result: (bubbles: [PaneBubble], paneCount: Int, error: String?) = await Task.detached(priority: .utility) {
                let panes: [TmuxPane]
                do {
                    panes = try collector.collect()
                } catch {
                    return (bubbles: [PaneBubble](), paneCount: 0, error: error.localizedDescription)
                }
                let events = eventStore.latestEventsByPane(maxAge: 30)
                let bubbles = panes.map { pane in
                    PaneBubble(
                        pane: pane,
                        summary: summarizer.summarize(pane, event: events[pane.paneId]),
                        lastEvent: events[pane.paneId]
                    )
                }
                return (bubbles: bubbles, paneCount: panes.count, error: nil)
            }.value

            isUpdating = false
            if let error = result.error {
                DebugLog.write("tmux collect failed: \(error)")
            }
            applyBubbles(result.bubbles, paneCount: result.paneCount)
        }
    }

    private func applyBubbles(_ bubbles: [PaneBubble], paneCount: Int) {
        overlayView.setBubbles(bubbles)
        fitWindow()
        if let snapshotPath = ProcessInfo.processInfo.environment["TMUXPAL_SNAPSHOT_PATH"] {
            overlayView.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }
        if lastLoggedBubbleCount != bubbles.count {
            DebugLog.write("updated panes=\(paneCount) bubbles=\(bubbles.count) frame=\(NSStringFromRect(window.frame))")
            lastLoggedBubbleCount = bubbles.count
        }
    }

    private func fitWindow() {
        fitWindow(keepingPalCenter: palAnchorScreenCenter ?? palScreenCenter())
    }

    private func fitWindow(keepingPalCenter palCenter: CGPoint) {
        updateBubbleLayout(forPalCenter: palCenter)
        applyPreferredFrame(keepingPalCenter: palCenter)
        palAnchorScreenCenter = clampToVisibleScreen()
        let visiblePalCenter = palScreenCenter()
        updateBubbleLayout(forPalCenter: visiblePalCenter)
        applyPreferredFrame(keepingPalCenter: visiblePalCenter)
        palAnchorScreenCenter = clampToVisibleScreen()
    }

    private func moveWindow(toScreenPoint screenPoint: CGPoint, grabOffset: CGPoint, horizontalDelta: CGFloat) {
        var frame = window.frame
        frame.origin.x = screenPoint.x - grabOffset.x
        frame.origin.y = screenPoint.y - grabOffset.y
        window.setFrame(frame, display: true)
        updateBubbleLayout()
        applyPreferredFrame(keepingPalCenter: palScreenCenter())
        palAnchorScreenCenter = clampToVisibleScreen()
        overlayView.setDragging(horizontalDelta: horizontalDelta)
        saveFrame()
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "overlayFrame")
    }

    @objc private func screenParametersDidChange() {
        palAnchorScreenCenter = clampToVisibleScreen()
        saveFrame()
    }

    @discardableResult
    private func clampToVisibleScreen() -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(palScreenCenter()) }) ?? NSScreen.main else {
            return palScreenCenter()
        }
        var frame = window.frame
        let visible = screen.visibleFrame
        let pal = overlayView.palRectInBounds()
        let palScreen = pal.offsetBy(dx: frame.minX, dy: frame.minY)
        if palScreen.minX < visible.minX {
            frame.origin.x += visible.minX - palScreen.minX
        }
        if palScreen.maxX > visible.maxX {
            frame.origin.x -= palScreen.maxX - visible.maxX
        }
        if palScreen.minY < visible.minY {
            frame.origin.y += visible.minY - palScreen.minY
        }
        if palScreen.maxY > visible.maxY {
            frame.origin.y -= palScreen.maxY - visible.maxY
        }
        window.setFrame(frame, display: true)
        return palScreenCenter()
    }

    private func applyPreferredFrame(keepingPalCenter palCenter: CGPoint) {
        let desired = overlayView.preferredSize()
        let palCenterInDesiredBounds = overlayView.palCenterInBounds(for: desired)
        var frame = window.frame
        frame.size = desired
        frame.origin.x = palCenter.x - palCenterInDesiredBounds.x
        frame.origin.y = palCenter.y - palCenterInDesiredBounds.y
        window.setFrame(frame, display: true)
    }

    private func updateBubbleLayout() {
        updateBubbleLayout(forPalCenter: palScreenCenter())
    }

    private func updateBubbleLayout(forPalCenter palCenter: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(palCenter) }) ?? NSScreen.main else {
            return
        }
        overlayView.updateBubbleLayout(palCenter: palCenter, visibleFrame: screen.visibleFrame)
    }

    private func palScreenCenter() -> CGPoint {
        let pal = overlayView.palRectInBounds()
        return CGPoint(x: window.frame.minX + pal.midX, y: window.frame.minY + pal.midY)
    }

    private static func savedFrame() -> NSRect {
        if ProcessInfo.processInfo.environment["TMUXPAL_RESET_POSITION"] == "1" {
            return defaultFrame()
        }
        if let text = UserDefaults.standard.string(forKey: "overlayFrame") {
            let rect = NSRectFromString(text)
            if rect.width > 10, rect.height > 10 {
                return rect
            }
        }
        return defaultFrame()
    }

    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.minX + 72, y: screen.maxY - 260, width: 408, height: 220)
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum BubbleHorizontalSide {
    case left
    case right
}

private enum BubbleVerticalSide {
    case above
    case below
}

@MainActor
final class OverlayView: NSView {
    static let basePalSize = NSSize(width: 77, height: 85)
    static let bubbleWidth: CGFloat = 280
    static let bubbleHeight: CGFloat = 76
    static let padding: CGFloat = 14
    static let expandedEdgePadding: CGFloat = 4
    static let bubblePalGap: CGFloat = 8
    static let expandedTransparentTopCompensationRatio: CGFloat = 0.24
    static let collapsedBadgeSize: CGFloat = 28
    static let collapsedBadgeRightOutset: CGFloat = 32
    static let collapsedBadgeTopOutset: CGFloat = 14
    static let collapsedBadgeHorizontalAnchor: CGFloat = 0.72

    var onDrag: ((_ screenPoint: CGPoint, _ grabOffset: CGPoint, _ horizontalDelta: CGFloat) -> Void)?
    var onClickPane: ((TmuxPane) -> Void)?
    var onCollapseChanged: (() -> Void)?

    private var bubbles: [PaneBubble] = []
    private var bubbleRects: [(NSRect, TmuxPane)] = []
    private var lastDragScreenPoint: NSPoint?
    private var dragGrabOffset: CGPoint?
    private var didDrag = false
    private var dragResetTimer: Timer?
    private var isHovering = false
    private var isDragging = false
    private var isCollapsed = ProcessInfo.processInfo.environment["TMUXPAL_COLLAPSED"] == "1"
        || UserDefaults.standard.bool(forKey: "bubblesCollapsed")
    private var animationState = "idle"
    private var lastHorizontalDragState = "running-right"
    private var frameIndex = 0
    private var framesByState: [String: [PalFrame]] = [:]
    private var animationTimer: Timer?
    private var palAssetConfig: PalAssetConfig
    private var palScale = PalSettings.displaySize.scale
    private let runClassifier = BubbleRunClassifier()
    private let badgeCounter = BubbleBadgeCounter()
    private var bubbleHorizontalSide: BubbleHorizontalSide = .left
    private var bubbleVerticalSide: BubbleVerticalSide = .above

    init(frame frameRect: NSRect = .zero, palAssetConfig: PalAssetConfig) {
        self.palAssetConfig = palAssetConfig
        super.init(frame: frameRect)
        reloadPalAssets()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceAnimation()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var palSize: NSSize {
        NSSize(
            width: Self.basePalSize.width * palScale,
            height: Self.basePalSize.height * palScale
        )
    }

    static func size(forBubbleCount count: Int, collapsed: Bool, palSize: NSSize) -> NSSize {
        if collapsed {
            return NSSize(
                width: palSize.width + padding * 2 + collapsedBadgeRightOutset,
                height: palSize.height + padding * 2 + collapsedBadgeTopOutset
            )
        }
        let bubbleStackHeight = Self.bubbleStackHeight(for: count)
        let height = palSize.height
            + bubbleStackHeight
            + padding * 2
            + bubblePalGap
            - expandedTransparentTopCompensation(for: palSize)
        return NSSize(width: bubbleWidth + padding * 2, height: height)
    }

    static func expandedTransparentTopCompensation(for palSize: NSSize) -> CGFloat {
        palSize.height * expandedTransparentTopCompensationRatio
    }

    static func bubbleStackHeight(for count: Int) -> CGFloat {
        CGFloat(count) * bubbleHeight + CGFloat(max(0, count - 1)) * 8
    }

    func preferredSize() -> NSSize {
        Self.size(forBubbleCount: max(1, min(6, bubbles.count)), collapsed: isCollapsed, palSize: palSize)
    }

    func updateBubbleLayout(palCenter: CGPoint, visibleFrame: NSRect) {
        guard !isCollapsed else { return }
        let count = max(1, min(6, bubbles.count))
        let stackHeight = Self.bubbleStackHeight(for: count)
        let requiredHorizontal = Self.bubbleWidth + Self.padding * 2
        let requiredVertical = stackHeight + Self.padding
        let size = palSize
        bubbleHorizontalSide = palCenter.x - size.width / 2 - requiredHorizontal < visibleFrame.minX ? .right : .left
        bubbleVerticalSide = palCenter.y + size.height / 2 + requiredVertical > visibleFrame.maxY ? .below : .above
        if palCenter.y - size.height / 2 - requiredVertical < visibleFrame.minY {
            bubbleVerticalSide = .above
        }
        needsDisplay = true
    }

    func palRectInBounds() -> NSRect {
        palRect()
    }

    func palCenterInBounds() -> CGPoint {
        let pal = palRect()
        return CGPoint(x: pal.midX, y: pal.midY)
    }

    func palCenterInBounds(for size: NSSize) -> CGPoint {
        let pal = palRect(in: NSRect(origin: .zero, size: size))
        return CGPoint(x: pal.midX, y: pal.midY)
    }

    func reloadPalAssets(config: PalAssetConfig? = nil) {
        if let config {
            palAssetConfig = config
        }
        framesByState = PalSpriteLoader(config: palAssetConfig).loadFrames()
        DebugLog.write("pal assets loaded states=\(framesByState.keys.sorted().joined(separator: ","))")
        needsDisplay = true
    }

    func setPalScale(_ scale: CGFloat) {
        palScale = scale
        needsDisplay = true
    }

    func setBubbles(_ bubbles: [PaneBubble]) {
        self.bubbles = bubbles.sorted { lhs, rhs in
            let leftSessionRank = lhs.pane.sessionName == "0" ? 0 : 1
            let rightSessionRank = rhs.pane.sessionName == "0" ? 0 : 1
            if leftSessionRank != rightSessionRank {
                return leftSessionRank < rightSessionRank
            }
            if lhs.pane.sessionName != rhs.pane.sessionName {
                return lhs.pane.sessionName < rhs.pane.sessionName
            }
            let leftWindow = Int(lhs.pane.windowIndex) ?? Int.max
            let rightWindow = Int(rhs.pane.windowIndex) ?? Int.max
            if leftWindow != rightWindow {
                return leftWindow < rightWindow
            }
            let leftPane = Int(lhs.pane.paneIndex) ?? Int.max
            let rightPane = Int(rhs.pane.paneIndex) ?? Int.max
            if leftPane != rightPane {
                return leftPane < rightPane
            }
            return lhs.pane.sessionName < rhs.pane.sessionName
        }
        if bubbles.isEmpty {
            setAnimationState("waiting")
        } else if bubbles.contains(where: { $0.lastEvent?.event.contains("exited") == true || $0.lastEvent?.event.contains("died") == true }) {
            setAnimationState("failed")
        } else if bubbles.contains(where: { $0.pane.active }) {
            setAnimationState("review")
        } else {
            setAnimationState("idle")
        }
        needsDisplay = true
    }

    func setDragging(horizontalDelta: CGFloat) {
        isDragging = true
        if horizontalDelta < -0.25 {
            lastHorizontalDragState = "running-left"
        } else if horizontalDelta > 0.25 {
            lastHorizontalDragState = "running-right"
        }
        animationState = lastHorizontalDragState
        dragResetTimer?.invalidate()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPal()
        if isCollapsed {
            drawCollapsedBadge()
        } else {
            drawBubbles()
        }
    }

    func writeSnapshot(to url: URL) {
        guard bounds.width > 0, bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url)
    }

    private func drawPal() {
        let palRect = palRect()
        let frames = framesByState[animationState] ?? framesByState["idle"] ?? []
        if let frame = frames.isEmpty ? nil : frames[frameIndex % frames.count] {
            frame.draw(in: palRect)
        } else {
            NSColor.systemGreen.withAlphaComponent(0.25).setFill()
            palRect.fill()
        }
    }

    private func drawBubbles() {
        bubbleRects.removeAll()
        let visibleBubbles = bubbles.isEmpty ? [placeholderBubble()] : Array(bubbles.prefix(6))
        let pal = palRect()
        let startX = bubbleHorizontalSide == .left
            ? pal.maxX - Self.bubbleWidth
            : pal.minX
        var y: CGFloat
        if bubbleVerticalSide == .above {
            let visualTop = pal.maxY - Self.expandedTransparentTopCompensation(for: palSize)
            y = visualTop + Self.bubblePalGap + Self.bubbleStackHeight(for: visibleBubbles.count) - Self.bubbleHeight
        } else {
            y = pal.minY - Self.bubblePalGap - Self.bubbleHeight
        }

        for bubble in visibleBubbles {
            let rect = NSRect(x: startX, y: y, width: Self.bubbleWidth, height: Self.bubbleHeight)
            drawBubble(rect: rect, bubble: bubble)
            bubbleRects.append((rect, bubble.pane))
            y -= Self.bubbleHeight + 8
        }
    }

    private func drawBubble(rect: NSRect, bubble: PaneBubble) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor.white.withAlphaComponent(0.92).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(bubble.pane.active ? 0.18 : 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1.0),
            .paragraphStyle: paragraph
        ]
        let parts = bubble.summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let headline = parts.first ?? bubble.summary
        let detail = parts.count > 1 ? parts[1] : ""
        let location = locationLabel(for: bubble.pane)
        let statusSize: CGFloat = 16
        let statusRect = NSRect(x: rect.maxX - 12 - statusSize, y: rect.maxY - 24, width: statusSize, height: statusSize)
        drawStatus(in: statusRect, state: runState(for: bubble))

        let locationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.50, alpha: 0.82),
            .paragraphStyle: paragraph
        ]
        let locationWidth = min(112, max(30, NSString(string: location).size(withAttributes: locationAttrs).width + 2))
        let locationRect = NSRect(x: statusRect.minX - 6 - locationWidth, y: rect.maxY - 24, width: locationWidth, height: 16)
        NSString(string: location).draw(in: locationRect, withAttributes: locationAttrs)

        let headlineRect = NSRect(x: rect.minX + 12, y: rect.maxY - 29, width: rect.width - 42 - locationWidth, height: 21)
        NSString(string: headline).draw(in: headlineRect, withAttributes: attrs)

        if !detail.isEmpty {
            let detailParagraph = NSMutableParagraphStyle()
            detailParagraph.lineBreakMode = .byTruncatingTail
            detailParagraph.lineSpacing = 1
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
                .paragraphStyle: detailParagraph
            ]
            let detailRect = NSRect(x: rect.minX + 12, y: rect.minY + 10, width: rect.width - 24, height: 34)
            detail.twoLineTruncated(width: detailRect.width, attributes: detailAttrs)
                .draw(in: detailRect, withAttributes: detailAttrs)
        }
    }

    private func drawStatus(in rect: NSRect, state: BubbleRunState) {
        let path = NSBezierPath(ovalIn: rect)
        let green = NSColor(calibratedRed: 0.04, green: 0.63, blue: 0.25, alpha: 1)
        if state == .running {
            green.withAlphaComponent(0.16).setFill()
            path.fill()
            green.setStroke()
            let spinner = NSBezierPath()
            let start = CGFloat(frameIndex % 12) * 30
            spinner.appendArc(
                withCenter: NSPoint(x: rect.midX, y: rect.midY),
                radius: rect.width / 2 - 1.5,
                startAngle: start,
                endAngle: start + 250,
                clockwise: false
            )
            spinner.lineWidth = 2.2
            spinner.lineCapStyle = .round
            spinner.stroke()
            return
        }
        green.withAlphaComponent(0.14).setFill()
        path.fill()
        green.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: green
        ]
        NSString(string: "✓").draw(in: rect.insetBy(dx: 3.5, dy: 1.2), withAttributes: attrs)
    }

    private func drawCollapsedBadge() {
        let count = completedAwaitingCount()
        let pal = palRect()
        let badgeSize = Self.collapsedBadgeSize
        let rect = NSRect(
            x: pal.minX + palSize.width * Self.collapsedBadgeHorizontalAnchor,
            y: pal.maxY - badgeSize + Self.collapsedBadgeTopOutset,
            width: badgeSize,
            height: badgeSize
        )
        let path = NSBezierPath(ovalIn: rect)
        NSColor(calibratedRed: 0.04, green: 0.63, blue: 0.25, alpha: 1).setFill()
        path.fill()
        let text = "\(count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = NSString(string: text).size(withAttributes: attrs)
        let textRect = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 0.5, width: size.width, height: size.height)
        NSString(string: text).draw(in: textRect, withAttributes: attrs)
    }

    private func locationLabel(for pane: TmuxPane) -> String {
        if pane.paneId == "%placeholder" {
            return ""
        }
        if pane.sessionName == "0" {
            return "\(pane.windowIndex).\(pane.paneIndex)"
        }
        return "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
    }

    private func placeholderBubble() -> PaneBubble {
        let pane = TmuxPane(
            sessionName: "",
            windowIndex: "",
            windowId: "",
            windowName: "tmux",
            paneIndex: "",
            paneId: "%placeholder",
            panePid: "",
            paneTty: "",
            currentCommand: "",
            currentPath: "",
            active: false,
            title: "",
            commandLine: "",
            tool: .codex,
            status: .idle
        )
        return PaneBubble(pane: pane, summary: "tmux AI pane を待機中")
    }

    private func palRect() -> NSRect {
        palRect(in: bounds)
    }

    private func palRect(in bounds: NSRect) -> NSRect {
        let size = palSize
        if isCollapsed {
            return NSRect(x: Self.padding, y: Self.padding, width: size.width, height: size.height)
        }
        let x = bubbleHorizontalSide == .left
            ? bounds.width - Self.expandedEdgePadding - size.width
            : Self.expandedEdgePadding
        let y = bubbleVerticalSide == .above
            ? Self.padding
            : bounds.height - Self.padding - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: "bubblesCollapsed")
        bubbleRects.removeAll()
        needsDisplay = true
        onCollapseChanged?()
    }

    private func completedAwaitingCount() -> Int {
        badgeCounter.completedAwaitingCount(in: bubbles)
    }

    private func runState(for bubble: PaneBubble) -> BubbleRunState {
        runClassifier.classify(bubble)
    }

    private func advanceAnimation() {
        frameIndex += 1
        if isDragging {
            animationState = lastHorizontalDragState
        } else if isHovering {
            animationState = "jumping"
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        setHovering()
    }

    override func mouseMoved(with event: NSEvent) {
        isHovering = true
        setHovering()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        setAnimationState(restingAnimationState())
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isHovering = false
        didDrag = false
        let screenPoint = NSEvent.mouseLocation
        lastDragScreenPoint = screenPoint
        guard let window else { return }
        dragGrabOffset = CGPoint(x: screenPoint.x - window.frame.minX, y: screenPoint.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastDragScreenPoint, let grabOffset = dragGrabOffset else { return }
        let current = NSEvent.mouseLocation
        let horizontalDelta = current.x - previous.x
        if abs(horizontalDelta) > 0.5 {
            didDrag = true
        }
        lastDragScreenPoint = current
        onDrag?(current, grabOffset, horizontalDelta)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag, palRect().contains(point) {
            toggleCollapsed()
        } else if !didDrag {
            for (rect, pane) in bubbleRects where rect.contains(point) && pane.paneId != "%placeholder" {
                onClickPane?(pane)
                break
            }
        }
        lastDragScreenPoint = nil
        dragGrabOffset = nil
        isDragging = false
        dragResetTimer?.invalidate()
        dragResetTimer = nil
        isHovering = true
        setHovering()
    }

    private func setHovering() {
        guard !isDragging else { return }
        animationState = "jumping"
        needsDisplay = true
    }

    private func setAnimationState(_ state: String) {
        guard !isDragging else { return }
        animationState = state
    }

    private func restingAnimationState() -> String {
        if bubbles.isEmpty {
            return "waiting"
        }
        if bubbles.contains(where: { $0.lastEvent?.event.contains("exited") == true || $0.lastEvent?.event.contains("died") == true }) {
            return "failed"
        }
        if bubbles.contains(where: { $0.pane.active }) {
            return "review"
        }
        return "idle"
    }
}

enum TerminalActivator {
    static func activatePreferredTerminal() {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundleId = app.bundleIdentifier?.lowercased() ?? ""
            return name.contains("ghostty")
                || bundleId.contains("ghostty")
                || name.contains("terminal")
                || bundleId == "com.apple.terminal"
                || name.contains("iterm")
                || bundleId.contains("iterm")
        }

        let preferred = candidates.first { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundleId = app.bundleIdentifier?.lowercased() ?? ""
            return name.contains("ghostty") || bundleId.contains("ghostty")
        } ?? candidates.first

        if let preferred {
            preferred.activate(options: [.activateAllWindows])
            let name = preferred.localizedName?.lowercased() ?? ""
            let bundleId = preferred.bundleIdentifier?.lowercased() ?? ""
            if name.contains("ghostty") || bundleId.contains("ghostty") {
                activateGhosttyByAppleScript()
            }
        }
    }

    private static func activateGhosttyByAppleScript() {
        var error: NSDictionary?
        NSAppleScript(source: #"tell application "Ghostty" to activate"#)?
            .executeAndReturnError(&error)
    }
}

private extension String {
    func twoLineTruncated(width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> NSString {
        let text = NSString(string: self)
        let words = self.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1 else {
            return text
        }

        var firstLine = ""
        var secondLine = ""
        var onSecondLine = false
        for word in words {
            let candidate = onSecondLine
                ? [secondLine, word].filter { !$0.isEmpty }.joined(separator: " ")
                : [firstLine, word].filter { !$0.isEmpty }.joined(separator: " ")
            let measured = NSString(string: candidate).size(withAttributes: attributes).width
            if measured <= width {
                if onSecondLine {
                    secondLine = candidate
                } else {
                    firstLine = candidate
                }
                continue
            }

            if !onSecondLine {
                onSecondLine = true
                secondLine = word
                continue
            }
            return NSString(string: "\(firstLine)\n\(secondLine)…")
        }

        if secondLine.isEmpty {
            return NSString(string: firstLine)
        }
        return NSString(string: "\(firstLine)\n\(secondLine)")
    }
}

struct PalFrame {
    let image: NSImage

    func draw(in rect: NSRect) {
        image.draw(in: rect)
    }
}

struct PalSpriteLoader {
    let config: PalAssetConfig
    let cellWidth: CGFloat = 192
    let cellHeight: CGFloat = 208

    func loadFrames() -> [String: [PalFrame]] {
        DebugLog.write("loading pal spritesheet=\(config.spritesheetURL.path)")
        guard let sheet = NSImage(contentsOf: config.spritesheetURL),
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [:]
        }

        var result: [String: [PalFrame]] = [:]
        for row in config.loadRows() {
            var frames: [PalFrame] = []
            for frame in 0..<row.frames {
                let crop = CGRect(x: CGFloat(frame) * cellWidth, y: CGFloat(row.row) * cellHeight, width: cellWidth, height: cellHeight)
                if let cropped = cgImage.cropping(to: crop) {
                    let image = NSImage(cgImage: cropped, size: NSSize(width: cellWidth, height: cellHeight))
                    frames.append(PalFrame(image: image))
                }
            }
            result[row.state] = frames
        }
        return result
    }
}

final class AppServerManager {
    private var process: Process?

    func startIfAvailable() {
        guard process == nil else { return }
        let codexCandidates = [
            ProcessInfo.processInfo.environment["TMUXPAL_CODEX_PATH"],
            Self.findExecutable("codex"),
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
        guard let codexPath = codexCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = [
            "app-server",
            "--listen", "ws://127.0.0.1:17387",
            "-c", "model=\"gpt-5.5\"",
            "-c", "model_reasoning_effort=\"low\""
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            self.process = process
            DebugLog.write("codex app-server started pid=\(process.processIdentifier)")
        } catch {
            self.process = nil
            DebugLog.write("codex app-server failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private static func findExecutable(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        return paths
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum DebugLog {
    private static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tmuxpal.debug.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}
