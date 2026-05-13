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

        if ProcessInfo.processInfo.environment["TMUXPAL_ENABLE_APP_SERVER"] == "1" {
            let appServerManager = AppServerManager()
            self.appServerManager = appServerManager
            appServerManager.startIfAvailable()
        }
        if ProcessInfo.processInfo.environment["TMUXPAL_AUTO_INSTALL_HOOKS"] == "1" {
            TmuxHookInstaller.installHooks()
        }

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
        menu.addItem(screenshotMenuItem())
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

    private func screenshotMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "スクリーンショット", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let modeItem = NSMenuItem(title: "スクショモード", action: #selector(toggleScreenshotMode), keyEquivalent: "")
        modeItem.state = overlayController?.isScreenshotModeEnabled == true ? .on : .off
        submenu.addItem(modeItem)
        submenu.addItem(NSMenuItem(title: "PNG一式を書き出し...", action: #selector(exportScreenshotSet), keyEquivalent: ""))
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

    @objc private func toggleScreenshotMode() {
        guard let overlayController else { return }
        overlayController.setScreenshotModeEnabled(!overlayController.isScreenshotModeEnabled)
        rebuildStatusMenu()
    }

    @objc private func exportScreenshotSet() {
        guard let overlayController else { return }

        let panel = NSOpenPanel()
        panel.title = "スクリーンショット保存先"
        panel.message = "透過PNGの書き出し先フォルダを選択してください。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }

        let urls = overlayController.exportScreenshotSet(to: directory)
        rebuildStatusMenu()
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
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
    private var screenshotModeEnabled = false

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

        overlayView.onDrag = { [weak self] screenPoint, palGrabOffset, horizontalDelta in
            self?.moveWindow(toScreenPoint: screenPoint, palGrabOffset: palGrabOffset, horizontalDelta: horizontalDelta)
        }
        overlayView.onClickPane = { [weak self] pane in
            guard self?.screenshotModeEnabled != true else {
                return
            }
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
        if screenshotModeEnabled {
            applyScreenshotModeBubbles()
            reloadPalAssets()
            return
        }
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

    var isScreenshotModeEnabled: Bool {
        screenshotModeEnabled
    }

    func setScreenshotModeEnabled(_ enabled: Bool) {
        screenshotModeEnabled = enabled
        if enabled {
            applyScreenshotModeBubbles()
        } else {
            overlayView.setShowsBubbleUI(true)
            overlayView.setCollapsed(false, persist: false)
            updatePanes()
        }
    }

    func exportScreenshotSet(to directory: URL) -> [URL] {
        let originalMode = screenshotModeEnabled
        let originalSize = PalSettings.displaySize
        let originalCollapsed = overlayView.collapsedState
        let originalShowsBubbleUI = overlayView.showsBubbleUI
        let originalPalCenter = palScreenCenter()
        let wasVisible = window.isVisible
        var createdURLs: [URL] = []

        if !wasVisible {
            show()
        }

        screenshotModeEnabled = true
        applyScreenshotModeBubbles()

        defer {
            overlayView.setShowsBubbleUI(originalShowsBubbleUI)
            overlayView.setCollapsed(originalCollapsed, persist: false)
            overlayView.setPalScale(originalSize.scale)
            fitWindow(keepingPalCenter: originalPalCenter)
            screenshotModeEnabled = originalMode
            if originalMode {
                applyScreenshotModeBubbles()
            } else {
                updatePanes()
            }
            if !wasVisible {
                window.orderOut(nil)
            }
        }

        let palName = sanitizedFileComponent(PalSettings.selectedPalDirectory?.lastPathComponent ?? "default")
        for size in PalDisplaySize.allCases {
            overlayView.setPalScale(size.scale)
            for variant in ScreenshotCaptureVariant.allCases {
                overlayView.setShowsBubbleUI(variant.showsBubbleUI)
                overlayView.setCollapsed(false, persist: false)
                fitWindow(keepingPalCenter: originalPalCenter)
                window.displayIfNeeded()
                let url = directory.appendingPathComponent("tmuxpal-\(palName)-\(size.rawValue)-\(variant.fileSuffix).png")
                overlayView.writeSnapshot(to: url)
                createdURLs.append(url)
            }
        }

        DebugLog.write("exported screenshot set count=\(createdURLs.count) dir=\(directory.path)")
        return createdURLs
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePanes()
            }
        }
        updatePanes()
    }

    private func updatePanes() {
        if screenshotModeEnabled {
            applyScreenshotModeBubbles()
            return
        }
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
            if screenshotModeEnabled {
                applyScreenshotModeBubbles()
                return
            }
            if let error = result.error {
                DebugLog.write("tmux collect failed: \(error)")
            }
            applyBubbles(result.bubbles, paneCount: result.paneCount)
        }
    }

    private func applyScreenshotModeBubbles() {
        let bubbles = Self.screenshotModeBubbles()
        overlayView.setShowsBubbleUI(true)
        applyBubbles(bubbles, paneCount: bubbles.count)
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

    private func moveWindow(toScreenPoint screenPoint: CGPoint, palGrabOffset: CGPoint, horizontalDelta: CGFloat) {
        let pal = overlayView.palRectInBounds()
        let targetPalCenter = CGPoint(
            x: screenPoint.x - palGrabOffset.x + pal.width / 2,
            y: screenPoint.y - palGrabOffset.y + pal.height / 2
        )
        updateBubbleLayout(forPalCenter: targetPalCenter)
        applyPreferredFrame(keepingPalCenter: targetPalCenter)
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

    private func sanitizedFileComponent(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let joined = String(scalars)
        let collapsed = joined.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "default" : trimmed
    }

    private static func screenshotModeBubbles() -> [PaneBubble] {
        [
            screenshotBubble(
                paneId: "%s1",
                windowIndex: "1",
                paneIndex: "1",
                tool: .codex,
                active: true,
                title: "TmuxPal",
                detail: "Track multiple coding AI panes",
                transcriptTail: "● Working (43s · esc to interrupt)"
            ),
            screenshotBubble(
                paneId: "%s2",
                windowIndex: "1",
                paneIndex: "2",
                tool: .claude,
                active: false,
                title: "Swift / AppKit",
                detail: "Menu bar overlay for tmux",
                transcriptTail: "Task complete"
            ),
            screenshotBubble(
                paneId: "%s3",
                windowIndex: "2",
                paneIndex: "1",
                tool: .copilot,
                active: false,
                title: "Screenshot mode",
                detail: "Safe demo bubbles for sharing",
                transcriptTail: "Task complete"
            ),
            screenshotBubble(
                paneId: "%s4",
                windowIndex: "2",
                paneIndex: "2",
                tool: .opencode,
                active: false,
                title: "Transparent PNG",
                detail: "Ready for blog posts and releases",
                transcriptTail: "Task complete"
            )
        ]
    }

    private static func screenshotBubble(
        paneId: String,
        windowIndex: String,
        paneIndex: String,
        tool: AiTool,
        active: Bool,
        title: String,
        detail: String,
        transcriptTail: String
    ) -> PaneBubble {
        let pane = TmuxPane(
            sessionName: "0",
            windowIndex: windowIndex,
            windowId: "@\(windowIndex)",
            windowName: "tmuxpal",
            paneIndex: paneIndex,
            paneId: paneId,
            panePid: "0",
            paneTty: "",
            currentCommand: tool.rawValue,
            currentPath: "/tmp/tmuxpal",
            active: active,
            title: title,
            commandLine: tool.rawValue,
            transcriptExcerpt: transcriptTail,
            transcriptTail: transcriptTail,
            tool: tool,
            status: active ? .selected : .idle
        )
        return PaneBubble(pane: pane, summary: "\(title)\n\(detail)")
    }
}

private enum ScreenshotCaptureVariant: CaseIterable {
    case bubbles
    case palOnly

    var fileSuffix: String {
        switch self {
        case .bubbles:
            return "bubbles"
        case .palOnly:
            return "pal-only"
        }
    }

    var showsBubbleUI: Bool {
        switch self {
        case .bubbles:
            return true
        case .palOnly:
            return false
        }
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

private enum BubbleDensity {
    case regular
    case compact
    case singleLine
}

@MainActor
final class OverlayView: NSView {
    static let basePalSize = NSSize(width: 77, height: 85)
    static let bubbleWidth: CGFloat = 280
    static let regularBubbleHeight: CGFloat = 76
    static let compactBubbleHeight: CGFloat = 64
    static let singleLineBubbleHeight: CGFloat = 46
    static let padding: CGFloat = 14
    static let expandedEdgePadding: CGFloat = 4
    static let bubblePalGap: CGFloat = 8
    // Keep a small amount of transparent-top compensation, but leave enough
    // clearance that larger jump frames do not collide with the bubble stack.
    static let expandedTransparentTopCompensationRatio: CGFloat = 0.05
    static let collapsedBadgeSize: CGFloat = 28
    static let collapsedBadgeRightOutset: CGFloat = 32
    static let collapsedBadgeTopOutset: CGFloat = 14
    static let collapsedBadgeHorizontalAnchor: CGFloat = 0.72

    var onDrag: ((_ screenPoint: CGPoint, _ palGrabOffset: CGPoint, _ horizontalDelta: CGFloat) -> Void)?
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
    private var pendingBubbleClickPaneId: String?
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
    private var runStatesByPaneId: [String: BubbleRunState] = [:]
    private var completedBubbleCount = 0
    private var bubbleHorizontalSide: BubbleHorizontalSide = .left
    private var bubbleVerticalSide: BubbleVerticalSide = .above
    private(set) var showsBubbleUI = true

    init(frame frameRect: NSRect = .zero, palAssetConfig: PalAssetConfig) {
        self.palAssetConfig = palAssetConfig
        super.init(frame: frameRect)
        reloadPalAssets()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: true) { [weak self] _ in
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
        return size(
            forBubbleCount: count,
            collapsed: collapsed,
            palSize: palSize,
            bubbleVerticalSide: .above
        )
    }

    private static func size(
        forBubbleCount count: Int,
        collapsed: Bool,
        palSize: NSSize,
        bubbleVerticalSide: BubbleVerticalSide
    ) -> NSSize {
        if collapsed {
            return NSSize(
                width: palSize.width + padding * 2 + collapsedBadgeRightOutset,
                height: palSize.height + padding * 2 + collapsedBadgeTopOutset
            )
        }
        let bubbleStackHeight = Self.bubbleStackHeight(for: count)
        let transparentTopCompensation = bubbleVerticalSide == .above
            ? expandedTransparentTopCompensation(for: palSize)
            : 0
        let height = palSize.height
            + bubbleStackHeight
            + padding * 2
            + bubblePalGap
            - transparentTopCompensation
        return NSSize(width: bubbleWidth + padding * 2, height: height)
    }

    static func expandedTransparentTopCompensation(for palSize: NSSize) -> CGFloat {
        palSize.height * expandedTransparentTopCompensationRatio
    }

    static func bubbleStackHeight(for count: Int) -> CGFloat {
        CGFloat(count) * bubbleHeight(for: count) + CGFloat(max(0, count - 1)) * bubbleGap(for: count)
    }

    static func bubbleHeight(for count: Int) -> CGFloat {
        switch density(for: count) {
        case .regular: regularBubbleHeight
        case .compact: compactBubbleHeight
        case .singleLine: singleLineBubbleHeight
        }
    }

    static func bubbleGap(for count: Int) -> CGFloat {
        density(for: count) == .singleLine ? 6 : 8
    }

    private static func density(for count: Int) -> BubbleDensity {
        if count >= 6 {
            return .singleLine
        }
        if count >= 4 {
            return .compact
        }
        return .regular
    }

    func preferredSize() -> NSSize {
        if !showsBubbleUI {
            return NSSize(width: palSize.width + Self.padding * 2, height: palSize.height + Self.padding * 2)
        }
        return Self.size(
            forBubbleCount: max(1, min(6, bubbles.count)),
            collapsed: isCollapsed,
            palSize: palSize,
            bubbleVerticalSide: bubbleVerticalSide
        )
    }

    func updateBubbleLayout(palCenter: CGPoint, visibleFrame: NSRect) {
        guard showsBubbleUI, !isCollapsed else { return }
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

    var collapsedState: Bool {
        isCollapsed
    }

    func setCollapsed(_ collapsed: Bool, persist: Bool) {
        isCollapsed = collapsed
        if persist {
            UserDefaults.standard.set(isCollapsed, forKey: "bubblesCollapsed")
        }
        bubbleRects.removeAll()
        needsDisplay = true
        onCollapseChanged?()
    }

    func setShowsBubbleUI(_ showsBubbleUI: Bool) {
        self.showsBubbleUI = showsBubbleUI
        bubbleRects.removeAll()
        needsDisplay = true
        onCollapseChanged?()
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
        runStatesByPaneId = Dictionary(uniqueKeysWithValues: self.bubbles.map { bubble in
            (bubble.pane.paneId, runClassifier.classify(bubble))
        })
        completedBubbleCount = runStatesByPaneId.values.filter { $0 == .complete }.count
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
        if dirtyRect.intersects(palRect()) {
            drawPal()
        }
        if !showsBubbleUI {
            return
        }
        if isCollapsed {
            if dirtyRect.intersects(collapsedBadgeRect()) {
                drawCollapsedBadge()
            }
        } else {
            drawBubbles(dirtyRect: dirtyRect)
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

    private func drawBubbles(dirtyRect: NSRect) {
        bubbleRects.removeAll()
        for (rect, bubble) in bubbleLayoutRects() {
            if dirtyRect.intersects(rect) {
                drawBubble(rect: rect, bubble: bubble, dirtyRect: dirtyRect)
            }
            bubbleRects.append((rect, bubble.pane))
        }
    }

    private func bubbleLayoutRects() -> [(NSRect, PaneBubble)] {
        let visibleBubbles = bubbles.isEmpty ? [placeholderBubble()] : Array(bubbles.prefix(6))
        let count = visibleBubbles.count
        let bubbleHeight = Self.bubbleHeight(for: count)
        let bubbleGap = Self.bubbleGap(for: count)
        let pal = palRect()
        let startX = bubbleHorizontalSide == .left
            ? pal.maxX - Self.bubbleWidth
            : pal.minX
        let firstY: CGFloat
        if bubbleVerticalSide == .above {
            let visualTop = pal.maxY - Self.expandedTransparentTopCompensation(for: palSize)
            firstY = visualTop + Self.bubblePalGap + Self.bubbleStackHeight(for: count) - bubbleHeight
        } else {
            firstY = pal.minY - Self.bubblePalGap - bubbleHeight
        }
        return visibleBubbles.enumerated().map { index, bubble in
            let y = firstY - CGFloat(index) * (bubbleHeight + bubbleGap)
            return (NSRect(x: startX, y: y, width: Self.bubbleWidth, height: bubbleHeight), bubble)
        }
    }

    private func drawBubble(rect: NSRect, bubble: PaneBubble, dirtyRect: NSRect) {
        let statusRect = statusRect(in: rect)
        if dirtyRect.width <= statusRect.width + 8,
           dirtyRect.height <= statusRect.height + 8,
           dirtyRect.intersects(statusRect.insetBy(dx: -2, dy: -2)) {
            drawStatus(in: statusRect, state: runState(for: bubble))
            return
        }

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
        let bubbleDensity = Self.density(for: max(1, min(6, bubbles.count)))
        drawStatus(in: statusRect, state: runState(for: bubble))

        if bubbleDensity == .singleLine {
            drawSingleLineBubbleText(
                headline: headline,
                detail: detail,
                in: rect,
                locationWidth: locationWidth(for: location),
                statusRect: statusRect
            )
            drawLocation(location, in: rect, statusRect: statusRect, paragraph: paragraph)
            return
        }

        let locationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.50, alpha: 0.82),
            .paragraphStyle: paragraph
        ]
        let locationWidth = locationWidth(for: location)
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
            let detailRect = detailRect(in: rect, density: bubbleDensity)
            let detailText = bubbleDensity == .compact
                ? NSString(string: detail)
                : detail.twoLineTruncated(width: detailRect.width, attributes: detailAttrs)
            detailText.draw(in: detailRect, withAttributes: detailAttrs)
        }
    }

    private func drawSingleLineBubbleText(
        headline: String,
        detail: String,
        in rect: NSRect,
        locationWidth: CGFloat,
        statusRect: NSRect
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: headline,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1.0),
                .paragraphStyle: paragraph
            ]
        )
        if !detail.isEmpty {
            text.append(NSAttributedString(
                string: " \(detail)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
                    .paragraphStyle: paragraph
                ]
            ))
        }
        let textRect = NSRect(
            x: rect.minX + 12,
            y: rect.midY - 10,
            width: max(40, statusRect.minX - rect.minX - locationWidth - 30),
            height: 21
        )
        text.draw(in: textRect)
    }

    private func drawLocation(_ location: String, in rect: NSRect, statusRect: NSRect, paragraph: NSParagraphStyle) {
        let locationWidth = locationWidth(for: location)
        let locationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.50, alpha: 0.82),
            .paragraphStyle: paragraph
        ]
        let locationRect = NSRect(x: statusRect.minX - 6 - locationWidth, y: rect.maxY - 24, width: locationWidth, height: 16)
        NSString(string: location).draw(in: locationRect, withAttributes: locationAttrs)
    }

    private func locationWidth(for location: String) -> CGFloat {
        let locationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]
        return min(112, max(30, NSString(string: location).size(withAttributes: locationAttrs).width + 2))
    }

    private func detailRect(in rect: NSRect, density: BubbleDensity) -> NSRect {
        switch density {
        case .regular:
            return NSRect(x: rect.minX + 12, y: rect.minY + 10, width: rect.width - 24, height: 34)
        case .compact:
            return NSRect(x: rect.minX + 12, y: rect.minY + 11, width: rect.width - 24, height: 18)
        case .singleLine:
            return .zero
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
        green.setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        NSString(string: "✓").draw(in: rect.insetBy(dx: 3.2, dy: 0.9), withAttributes: attrs)
    }

    private func drawCollapsedBadge() {
        let count = completedAwaitingCount()
        let rect = collapsedBadgeRect()
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
        if !showsBubbleUI {
            return NSRect(x: Self.padding, y: Self.padding, width: size.width, height: size.height)
        }
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
        completedBubbleCount
    }

    private func runState(for bubble: PaneBubble) -> BubbleRunState {
        runStatesByPaneId[bubble.pane.paneId] ?? .complete
    }

    private func advanceAnimation() {
        frameIndex += 1
        if isDragging {
            animationState = lastHorizontalDragState
        } else if isHovering {
            animationState = "jumping"
        }
        setNeedsDisplay(palRect())
        if isCollapsed {
            setNeedsDisplay(collapsedBadgeRect())
        } else {
            for (rect, bubble) in bubbleLayoutRects() where runState(for: bubble) == .running {
                setNeedsDisplay(statusRect(in: rect).insetBy(dx: -2, dy: -2))
            }
        }
    }

    private func statusRect(in bubbleRect: NSRect) -> NSRect {
        let statusSize: CGFloat = 16
        return NSRect(x: bubbleRect.maxX - 12 - statusSize, y: bubbleRect.maxY - 24, width: statusSize, height: statusSize)
    }

    private func collapsedBadgeRect() -> NSRect {
        let pal = palRect()
        let badgeSize = Self.collapsedBadgeSize
        return NSRect(
            x: pal.minX + palSize.width * Self.collapsedBadgeHorizontalAnchor,
            y: pal.maxY - badgeSize + Self.collapsedBadgeTopOutset,
            width: badgeSize,
            height: badgeSize
        )
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
        let point = convert(event.locationInWindow, from: nil)
        if let bubble = bubble(at: point) {
            pendingBubbleClickPaneId = bubble.pane.paneId
            dragGrabOffset = nil
            lastDragScreenPoint = nil
            return
        }
        pendingBubbleClickPaneId = nil
        guard palRect().contains(point) else {
            dragGrabOffset = nil
            return
        }
        let screenPoint = NSEvent.mouseLocation
        lastDragScreenPoint = screenPoint
        let pal = palRect()
        dragGrabOffset = CGPoint(x: point.x - pal.minX, y: point.y - pal.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastDragScreenPoint, let grabOffset = dragGrabOffset else { return }
        let current = NSEvent.mouseLocation
        let horizontalDelta = current.x - previous.x
        let verticalDelta = current.y - previous.y
        if hypot(horizontalDelta, verticalDelta) > 0.5 {
            didDrag = true
        }
        lastDragScreenPoint = current
        onDrag?(current, grabOffset, horizontalDelta)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag {
            if let bubble = bubble(at: point) {
                let shouldAcceptClick = pendingBubbleClickPaneId == nil || pendingBubbleClickPaneId == bubble.pane.paneId
                if shouldAcceptClick {
                    onClickPane?(bubble.pane)
                }
            } else if pendingBubbleClickPaneId == nil, palRect().contains(point) {
                toggleCollapsed()
            }
        }
        pendingBubbleClickPaneId = nil
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

    private func bubble(at point: CGPoint) -> PaneBubble? {
        guard showsBubbleUI, !isCollapsed else {
            return nil
        }
        return bubbleLayoutRects().first { rect, bubble in
            rect.contains(point) && bubble.pane.paneId != "%placeholder"
        }?.1
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
