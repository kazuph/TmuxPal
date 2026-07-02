import AppKit
import Foundation
import Security
import ServiceManagement
import SQLite3
import TmuxPalCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayController?
    private var appServerManager: AppServerManager?
    private var latestCodexUsageSnapshot: CodexUsageSnapshot?
    private var latestClaudeUsageSnapshot: ClaudeUsageSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.shouldContinueLaunching() else {
            DebugLog.write("app exiting because another instance is already running")
            NSApp.terminate(nil)
            return
        }
        // Regular policy so TmuxPal shows up in the Dock and the Cmd+Tab app
        // switcher; selecting it there raises the overlay.
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
        try? AppSupport.ensureSupportDirectory()
        DebugLog.write("app launched")

        let overlayController = OverlayController()
        self.overlayController = overlayController
        overlayController.onUsageChanged = { [weak self] codexSnapshot, claudeSnapshot in
            self?.latestCodexUsageSnapshot = codexSnapshot
            self?.latestClaudeUsageSnapshot = claudeSnapshot
            self?.rebuildStatusMenu()
        }
        overlayController.show()

        if ProcessInfo.processInfo.environment["TMUXPAL_ENABLE_APP_SERVER"] == "1" {
            let appServerManager = AppServerManager()
            self.appServerManager = appServerManager
            appServerManager.startIfAvailable()
        }

        configureStatusItem()
        if ProcessInfo.processInfo.environment["TMUXPAL_AUTO_INSTALL_HOOKS"] == "1" {
            confirmAndInstallTmuxHooks(startup: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("app terminating")
        appServerManager?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        overlayController?.bringToFront()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlayController?.bringToFront()
        return false
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Show Overlay", action: #selector(reloadOverlay), keyEquivalent: "r"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit TmuxPal", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatusBarLimitImage.size.width + 6)
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        updateStatusButton()
        let menu = NSMenu()
        for item in StatusBarLimitImage.menuItems(
            codexSnapshot: latestCodexUsageSnapshot,
            claudeSnapshot: latestClaudeUsageSnapshot,
            target: self,
            action: #selector(ignoreLimitMenuItem(_:))
        ) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show/Hide", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadOverlay), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(palSelectionMenuItem())
        menu.addItem(palSizeMenuItem())
        menu.addItem(NSMenuItem(title: "Use Default Pal", action: #selector(useDefaultPal), keyEquivalent: ""))
        menu.addItem(palGalleryMenuItem())
        menu.addItem(screenshotMenuItem())
        menu.addItem(usageRingModeMenuItem())
        let alwaysOnTopItem = NSMenuItem(
            title: "Always on Top",
            action: #selector(toggleAlwaysOnTop),
            keyEquivalent: ""
        )
        alwaysOnTopItem.state = overlayController?.isAlwaysOnTop == true ? .on : .off
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Install/Update tmux Hooks...", action: #selector(reinstallTmuxHooks), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Remove tmux Hooks...", action: #selector(uninstallTmuxHooks), keyEquivalent: ""))
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.variableLength
        button.title = StatusBarLimitImage.compactTitle(
            codexSnapshot: latestCodexUsageSnapshot,
            claudeSnapshot: latestClaudeUsageSnapshot
        )
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        button.image = PalSettings.statusBarImage(
            codexSnapshot: latestCodexUsageSnapshot,
            claudeSnapshot: latestClaudeUsageSnapshot
        )
        button.imagePosition = .imageLeft
        button.toolTip = StatusBarLimitImage.tooltip(
            codexSnapshot: latestCodexUsageSnapshot,
            claudeSnapshot: latestClaudeUsageSnapshot
        )
    }

    private func palSelectionMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "Choose Pal", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let palDirectories = PalSettings.discoveredPalDirectories()

        if palDirectories.isEmpty {
            submenu.addItem(NSMenuItem(title: "Choose from File...", action: #selector(selectPalFromFile), keyEquivalent: ""))
        } else {
            for directory in palDirectories {
                let item = NSMenuItem(
                    title: PalSettings.displayName(forPalDirectory: directory),
                    action: #selector(selectDiscoveredPal(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = directory
                item.state = PalSettings.selectedPalDirectory?.standardizedFileURL == directory.standardizedFileURL ? .on : .off
                item.image = PalSettings.previewImage(forPalDirectory: directory)
                submenu.addItem(item)
            }
        }

        rootItem.submenu = submenu
        return rootItem
    }

    private func palGalleryMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "Find Pals", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Open Petdex", action: #selector(openPetdex), keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Open awesome-codex-pet", action: #selector(openAwesomeCodexPet), keyEquivalent: ""))
        rootItem.submenu = submenu
        return rootItem
    }

    private func palSizeMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
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
        let rootItem = NSMenuItem(title: "Screenshots", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let modeItem = NSMenuItem(title: "Screenshot Mode", action: #selector(toggleScreenshotMode), keyEquivalent: "")
        modeItem.state = overlayController?.isScreenshotModeEnabled == true ? .on : .off
        submenu.addItem(modeItem)
        submenu.addItem(NSMenuItem(title: "Export PNG Set...", action: #selector(exportScreenshotSet), keyEquivalent: ""))
        rootItem.submenu = submenu
        return rootItem
    }

    private func usageRingModeMenuItem() -> NSMenuItem {
        let rootItem = NSMenuItem(title: "Codex usage rings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentMode = overlayController?.usageRingMode ?? .rings
        for mode in UsageRingDisplayMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(selectUsageRingMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = currentMode == mode ? .on : .off
            submenu.addItem(item)
        }
        rootItem.submenu = submenu
        return rootItem
    }

    @objc private func toggleOverlay() {
        overlayController?.toggle()
    }

    @objc private func ignoreLimitMenuItem(_ sender: NSMenuItem) {}

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
        panel.title = "Choose Pal"
        panel.message = "Choose a folder containing pal.json, or choose pal.json directly."
        panel.directoryURL = PalSettings.defaultPalPickerDirectory()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard PalSettings.validatePalDirectory(directory) else {
            DebugLog.write("pal selection ignored: invalid pal package in \(directory.path)")
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

    @objc private func toggleAlwaysOnTop() {
        guard let overlayController else { return }
        overlayController.setAlwaysOnTop(!overlayController.isAlwaysOnTop)
        rebuildStatusMenu()
    }

    @objc private func selectUsageRingMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UsageRingDisplayMode(rawValue: rawValue) else {
            return
        }
        overlayController?.setUsageRingMode(mode)
        rebuildStatusMenu()
    }

    @objc private func openPetdex() {
        NSWorkspace.shared.open(URL(string: "https://petdex.crafter.run")!)
    }

    @objc private func openAwesomeCodexPet() {
        NSWorkspace.shared.open(URL(string: "https://awesome-codex-pet.pages.dev")!)
    }

    @objc private func exportScreenshotSet() {
        guard let overlayController else { return }

        let panel = NSOpenPanel()
        panel.title = "Screenshot Export Folder"
        panel.message = "Choose a folder for transparent PNG exports."
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
        confirmAndInstallTmuxHooks(startup: false)
    }

    @objc private func uninstallTmuxHooks() {
        guard confirmTmuxHookRemoval() else { return }
        TmuxHookInstaller.uninstallHooks()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func confirmAndInstallTmuxHooks(startup: Bool) {
        guard confirmTmuxHookInstall(startup: startup) else { return }
        TmuxHookInstaller.installHooks()
    }

    private func confirmTmuxHookInstall(startup: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = startup ? "Install tmux hooks?" : "Install or update tmux hooks?"
        alert.informativeText = """
        TmuxPal can install global tmux hooks to update pane lifecycle state immediately when panes are created, selected, or closed.

        \(TmuxHookInstaller.installExplanation)

        This is optional. You can remove these hooks later from the TmuxPal menu.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmTmuxHookRemoval() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove tmux hooks?"
        alert.informativeText = """
        TmuxPal will remove only its own tmux hooks from slot \(TmuxHookInstaller.hookSlot).

        Pane discovery still works without hooks, but lifecycle updates may be less immediate.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Hooks")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
    private static let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { value -> URL? in
        value.isEmpty ? nil : URL(fileURLWithPath: value)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private static let userCharacterRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/tmuxpal/characters")
    private static let legacyCharacterRoot = codexHome.appendingPathComponent(["pe", "ts"].joined())

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
                    && validatePalDirectory(url)
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

    static func previewImage(forPalDirectory directory: URL) -> NSImage? {
        guard let metadataURL = metadataURL(in: directory) else { return nil }
        return firstFrameImage(for: PalAssetConfig(metadataURL: metadataURL), size: NSSize(width: 20, height: 22))
    }

    static func statusBarImage(codexSnapshot: CodexUsageSnapshot?, claudeSnapshot: ClaudeUsageSnapshot?) -> NSImage? {
        StatusBarLimitImage.make(
            palImage: firstFrameImage(for: assetConfig(), size: NSSize(width: 18, height: 20)),
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            codexPalette: UsageRingPalette.derived(from: PalSpriteLoader(config: assetConfig()).dominantColor()),
            claudePalette: UsageRingPalette.derived(from: UsageRingPalette.claudeBase)
        )
    }

    private static func firstFrameImage(for config: PalAssetConfig, size: NSSize) -> NSImage? {
        guard validateSpritesheet(config.spritesheetURL),
              let sheet = NSImage(contentsOf: config.spritesheetURL),
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cgImage.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: size)
        image.isTemplate = false
        return image
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

    static func validatePalDirectory(_ directory: URL) -> Bool {
        guard let metadataURL = metadataURL(in: directory),
              let data = try? Data(contentsOf: metadataURL),
              let request = try? JSONDecoder().decode(PalRequest.self, from: data),
              !request.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return validateSpritesheet(PalAssetConfig(metadataURL: metadataURL).spritesheetURL)
    }

    private static func validateSpritesheet(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              ["webp", "png"].contains(url.pathExtension.lowercased()),
              let sheet = NSImage(contentsOf: url),
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        return cgImage.width == 1536 && cgImage.height == 1872
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

private enum StatusBarLimitImage {
    static let size = NSSize(width: 64, height: 22)

    private struct Row {
        let label: String
        let bucket: CodexUsageBucket?
        let color: NSColor
    }

    static func make(
        palImage: NSImage?,
        codexSnapshot: CodexUsageSnapshot?,
        claudeSnapshot: ClaudeUsageSnapshot?,
        codexPalette: UsageRingPalette,
        claudePalette: UsageRingPalette
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        palImage?.draw(in: NSRect(x: 0, y: 1, width: 18, height: 20))

        let rows = rows(
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            codexPalette: codexPalette,
            claudePalette: claudePalette
        )
        for (index, row) in rows.enumerated() {
            draw(row: row, y: size.height - 4.5 - CGFloat(index) * 5.0)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func tooltip(codexSnapshot: CodexUsageSnapshot?, claudeSnapshot: ClaudeUsageSnapshot?) -> String {
        usageRows(codexSnapshot: codexSnapshot, claudeSnapshot: claudeSnapshot)
            .map { row in
                guard let bucket = row.bucket else { return "\(row.label): --" }
                return "\(row.label): \(Int(round(bucket.remainingPercent)))% remaining, reset \(resetText(for: bucket))"
            }
            .joined(separator: "\n")
    }

    static func menuItems(
        codexSnapshot: CodexUsageSnapshot?,
        claudeSnapshot: ClaudeUsageSnapshot?,
        target: AnyObject?,
        action: Selector?
    ) -> [NSMenuItem] {
        usageRows(codexSnapshot: codexSnapshot, claudeSnapshot: claudeSnapshot).map { row in
            let item = NSMenuItem(
                title: "\(row.label): \(limitText(for: row.bucket))",
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            return item
        }
    }

    static func compactTitle(codexSnapshot: CodexUsageSnapshot?, claudeSnapshot: ClaudeUsageSnapshot?) -> String {
        let claudeWeekly = compactPercent(claudeSnapshot?.sevenDay)
        let claudeFiveHour = compactPercent(claudeSnapshot?.fiveHour)
        let codexWeekly = compactPercent(codexSnapshot?.weekly)
        let codexFiveHour = compactPercent(codexSnapshot?.shortTerm)
        return " C \(claudeWeekly)/\(claudeFiveHour) X \(codexWeekly)/\(codexFiveHour)"
    }

    private static func rows(
        codexSnapshot: CodexUsageSnapshot?,
        claudeSnapshot: ClaudeUsageSnapshot?,
        codexPalette: UsageRingPalette,
        claudePalette: UsageRingPalette
    ) -> [Row] {
        [
            Row(label: "CC W", bucket: claudeSnapshot?.sevenDay, color: claudePalette.weekly),
            Row(label: "CC 5h", bucket: claudeSnapshot?.fiveHour, color: claudePalette.shortTerm),
            Row(label: "CX W", bucket: codexSnapshot?.weekly, color: codexPalette.weekly),
            Row(label: "CX 5h", bucket: codexSnapshot?.shortTerm, color: codexPalette.shortTerm)
        ]
    }

    private static func usageRows(
        codexSnapshot: CodexUsageSnapshot?,
        claudeSnapshot: ClaudeUsageSnapshot?
    ) -> [(label: String, bucket: CodexUsageBucket?)] {
        [
            ("Claude Code W", claudeSnapshot?.sevenDay),
            ("Claude Code 5h", claudeSnapshot?.fiveHour),
            ("Codex W", codexSnapshot?.weekly),
            ("Codex 5h", codexSnapshot?.shortTerm)
        ]
    }

    private static func limitText(for bucket: CodexUsageBucket?) -> String {
        guard let bucket else {
            return "-- remaining, reset --"
        }
        return "\(Int(round(bucket.remainingPercent)))% remaining, reset \(resetText(for: bucket))"
    }

    private static func compactPercent(_ bucket: CodexUsageBucket?) -> String {
        guard let bucket else { return "--" }
        return "\(Int(round(bucket.remainingPercent)))"
    }

    private static func resetText(for bucket: CodexUsageBucket) -> String {
        guard let resetAt = bucket.resetAt else {
            return "--"
        }
        let normalizedResetAt = resetAt > 10_000_000_000 ? resetAt / 1000.0 : resetAt
        return Self.resetDateFormatter.string(from: Date(timeIntervalSince1970: normalizedResetAt))
    }

    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("M/d HH:mm")
        return formatter
    }()

    private static func draw(row: Row, y: CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 4.4, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
        ]
        NSString(string: row.label).draw(at: CGPoint(x: 20, y: y - 0.8), withAttributes: labelAttrs)

        let trackRect = NSRect(x: 39, y: y, width: 22, height: 2.5)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 1.3, yRadius: 1.3).fill()

        guard let bucket = row.bucket else {
            drawUnavailableMarks(in: trackRect)
            return
        }

        let fillWidth = max(1.0, trackRect.width * CGFloat(bucket.remainingPercent / 100.0))
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
        row.color.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.3, yRadius: 1.3).fill()
    }

    private static func drawUnavailableMarks(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 3.9, weight: .regular),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.34)
        ]
        NSString(string: "----").draw(at: CGPoint(x: rect.midX - 6, y: rect.minY - 1.2), withAttributes: attrs)
    }
}

enum PalDisplaySize: String, CaseIterable {
    case small
    case medium
    case large

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
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
    static var hookSlot: Int {
        Int(ProcessInfo.processInfo.environment["TMUXPAL_HOOK_SLOT"] ?? "") ?? 900
    }

    static var installExplanation: String {
        """
        It writes tmux global hooks in slot \(hookSlot): \(hookNames.joined(separator: ", ")).
        Each hook runs tmuxpal-hook.sh and appends a small event record under TmuxPal's app support directory.
        """
    }

    static func installHooks() {
        guard let tmux = tmuxExecutable() else {
            DebugLog.write("tmux hook install skipped: tmux executable not found")
            return
        }
        guard let script = stableHookScriptURL() else {
            DebugLog.write("tmux hook install skipped: tmuxpal-hook.sh not found")
            return
        }

        let slot = hookSlot
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
        let slot = hookSlot
        for hookName in hookNames {
            _ = run(tmux, arguments: ["set-hook", "-gu", "\(hookName)[\(slot)]"])
        }
        DebugLog.write("tmux hooks removed slot=\(slot)")
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

struct CodexUsageReader {
    private let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func readLatest() async -> CodexUsageSnapshot? {
        if let live = await readLiveUsage() {
            return live
        }
        return readLatestLog()
    }

    private func readLiveUsage() async -> CodexUsageSnapshot? {
        guard let token = accessToken() else { return nil }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID = accountID(fromAccessToken: token) {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return CodexUsageParser.snapshot(from: data, source: "live")
    }

    private func accessToken() -> String? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func accountID(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }

    private func readLatestLog() -> CodexUsageSnapshot? {
        let logsURL = codexHome.appendingPathComponent("logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: logsURL.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(logsURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let body = String(cString: text)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return CodexUsageParser.snapshot(from: data, source: "log")
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start
        while index < body.endIndex {
            let character = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(body[start...index])
                }
            }
            index = body.index(after: index)
        }
        return nil
    }
}

/// Reads Claude Code rate limits. Preferred source is a statusline cache file
/// (see README: a Claude Code statusline script that dumps the `rate_limits`
/// JSON it receives on stdin) because it needs no keychain access and never
/// hits the network. When the cache is absent or stale it falls back to
/// api.anthropic.com/api/oauth/usage with the Claude Code OAuth token from
/// ~/.claude/.credentials.json or the macOS keychain. The live endpoint rate
/// limits aggressively, so fetches are throttled and failures back off.
actor ClaudeUsageReader {
    static let maxCacheAge: TimeInterval = 24 * 60 * 60
    static let liveFetchInterval: TimeInterval = 5 * 60
    static let liveFailureBackoff: TimeInterval = 15 * 60
    static let keychainService = "Claude Code-credentials"

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var claudeHome: URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configDir.isEmpty {
            return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    private var lastLiveSnapshot: ClaudeUsageSnapshot?
    private var lastLiveAttempt: Date?
    private var liveRetryInterval: TimeInterval = 0
    private var cachedAccessToken: String?

    func readLatest() async -> ClaudeUsageSnapshot? {
        if let cached = readStatuslineCache() {
            return cached
        }
        return await readLiveUsage()
    }

    private var cacheURL: URL {
        if let override = ProcessInfo.processInfo.environment["TMUXPAL_CLAUDE_USAGE_CACHE"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return claudeHome.appendingPathComponent("cache/statusline-rate-limits.json")
    }

    private func readStatuslineCache() -> ClaudeUsageSnapshot? {
        let url = cacheURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) <= Self.maxCacheAge,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return ClaudeUsageParser.snapshot(from: data, source: "statusline-cache")
    }

    private func readLiveUsage() async -> ClaudeUsageSnapshot? {
        let now = Date()
        if let lastLiveAttempt, now.timeIntervalSince(lastLiveAttempt) < liveRetryInterval {
            return freshEnough(lastLiveSnapshot)
        }
        lastLiveAttempt = now
        guard let token = accessToken() else {
            DebugLog.write("claude usage: no oauth token available; skipping live fetch")
            liveRetryInterval = Self.liveFailureBackoff
            return freshEnough(lastLiveSnapshot)
        }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Without a claude-code user agent this endpoint serves a far stricter
        // 429 bucket, which makes polling unusable.
        request.setValue("claude-code/2.1.80", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            DebugLog.write("claude usage: live fetch failed (network)")
            liveRetryInterval = Self.liveFailureBackoff
            return freshEnough(lastLiveSnapshot)
        }
        guard (200..<300).contains(http.statusCode),
              let snapshot = ClaudeUsageParser.snapshot(from: data, source: "live") else {
            DebugLog.write("claude usage: live fetch failed status=\(http.statusCode)")
            if http.statusCode == 401 || http.statusCode == 403 {
                cachedAccessToken = nil
            }
            liveRetryInterval = Self.liveFailureBackoff
            return freshEnough(lastLiveSnapshot)
        }
        DebugLog.write("claude usage: live fetch ok fiveHour=\(snapshot.fiveHour != nil) sevenDay=\(snapshot.sevenDay != nil)")
        liveRetryInterval = Self.liveFetchInterval
        lastLiveSnapshot = snapshot
        return snapshot
    }

    private func freshEnough(_ snapshot: ClaudeUsageSnapshot?) -> ClaudeUsageSnapshot? {
        guard let snapshot,
              Date().timeIntervalSince(snapshot.observedAt) <= Self.maxCacheAge else {
            return nil
        }
        return snapshot
    }

    private func accessToken() -> String? {
        if let cachedAccessToken {
            return cachedAccessToken
        }
        if let token = credentialsFileToken() {
            cachedAccessToken = token
            return token
        }
        if let token = keychainToken() {
            cachedAccessToken = token
            return token
        }
        return nil
    }

    private func credentialsFileToken() -> String? {
        let url = claudeHome.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return oauthToken(from: data)
    }

    private func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            DebugLog.write("claude usage: keychain lookup failed status=\(status)")
            return nil
        }
        guard let items = item as? [[String: Any]] else {
            DebugLog.write("claude usage: keychain lookup returned unexpected item")
            return nil
        }
        for account in tokenKeychainAccounts(from: items) {
            guard let data = keychainData(account: account),
                  let token = oauthToken(from: data) else {
                continue
            }
            DebugLog.write("claude usage: oauth token loaded from keychain account=\(account)")
            return token
        }
        DebugLog.write("claude usage: no usable oauth token in keychain")
        return nil
    }

    private func tokenKeychainAccounts(from items: [[String: Any]]) -> [String] {
        items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { !$0.localizedCaseInsensitiveContains("Assistant Identifier") }
    }

    private func keychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            DebugLog.write("claude usage: keychain data lookup failed account=\(account) status=\(status)")
            return nil
        }
        guard let data = item as? Data else {
            DebugLog.write("claude usage: keychain data lookup returned unexpected item account=\(account)")
            return nil
        }
        return data
    }

    private func oauthToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        if let expiresAt = oauth["expiresAt"] as? Double {
            let expirySeconds = expiresAt > 10_000_000_000 ? expiresAt / 1000.0 : expiresAt
            guard expirySeconds > Date().timeIntervalSince1970 + 60 else {
                DebugLog.write("claude usage: oauth token expired; waiting for claude code to refresh it")
                return nil
            }
        }
        return token
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
    private var usageTimer: Timer?
    private let codexUsageReader = CodexUsageReader()
    private let claudeUsageReader = ClaudeUsageReader()
    var onUsageChanged: ((CodexUsageSnapshot?, ClaudeUsageSnapshot?) -> Void)?

    init() {
        overlayView = OverlayView(palAssetConfig: PalSettings.assetConfig())
        window = OverlayPanel(
            contentRect: OverlayController.savedFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = overlayView
        window.ignoresMouseEvents = false
        applyWindowLevel()
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
                self?.overlayView.setHighlightedPaneId(pane.paneId, manual: true)
                DebugLog.write("focused pane=\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex) \(pane.paneId)")
            } catch {
                DebugLog.write("focus failed pane=\(pane.paneId): \(error.localizedDescription)")
            }
            TerminalActivator.activatePreferredTerminal(for: pane)
        }
        overlayView.onCollapseChanged = { [weak self] in
            self?.fitWindow()
        }
        overlayView.onAttentionRaised = { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.window.orderFrontRegardless()
            DebugLog.write("overlay raised to front after task completion")
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
        startUsageTimer()
    }

    func toggle() {
        window.isVisible ? window.orderOut(nil) : show()
    }

    /// Raises the overlay, re-showing it first if it was hidden. Called when
    /// the user picks TmuxPal in the Dock or the Cmd+Tab switcher.
    func bringToFront() {
        guard window.isVisible else {
            show()
            return
        }
        window.orderFrontRegardless()
    }

    func reloadNow() {
        if screenshotModeEnabled {
            applyScreenshotModeBubbles()
            reloadPalAssets()
            return
        }
        updatePanes()
        reloadPalAssets()
        Task { await reloadUsage() }
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

    var usageRingMode: UsageRingDisplayMode {
        overlayView.usageRingMode
    }

    static let alwaysOnTopDefaultsKey = "overlayAlwaysOnTop"

    var isAlwaysOnTop: Bool {
        UserDefaults.standard.bool(forKey: Self.alwaysOnTopDefaultsKey)
    }

    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopDefaultsKey)
        applyWindowLevel()
        if alwaysOnTop, window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// The overlay lives at normal window level by default so other windows
    /// can cover it; it only jumps to the front when a task completes. The
    /// "Always on Top" menu toggle restores the legacy floating behavior.
    private func applyWindowLevel() {
        window.level = isAlwaysOnTop ? .statusBar : .normal
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

    func setUsageRingMode(_ mode: UsageRingDisplayMode) {
        overlayView.setUsageRingMode(mode)
        fitWindow()
        Task { await reloadUsage() }
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

    private func startUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.reloadUsage()
            }
        }
        Task { await reloadUsage() }
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
            overlayView.displayIfNeeded()
            overlayView.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }
        if lastLoggedBubbleCount != bubbles.count {
            DebugLog.write("updated panes=\(paneCount) bubbles=\(bubbles.count) frame=\(NSStringFromRect(window.frame))")
            lastLoggedBubbleCount = bubbles.count
        }
    }

    private func reloadUsage() async {
        let codexReader = codexUsageReader
        let claudeReader = claudeUsageReader
        async let codexSnapshot = Task.detached(priority: .utility) {
            await codexReader.readLatest()
        }.value
        async let claudeSnapshot = Task.detached(priority: .utility) {
            await claudeReader.readLatest()
        }.value
        let nextCodexSnapshot = await codexSnapshot
        let nextClaudeSnapshot = await claudeSnapshot
        onUsageChanged?(nextCodexSnapshot, nextClaudeSnapshot)
        if overlayView.showsUsageRings {
            overlayView.setUsageSnapshot(nextCodexSnapshot)
            overlayView.setClaudeUsageSnapshot(nextClaudeSnapshot)
        } else {
            overlayView.setUsageSnapshot(nil)
            overlayView.setClaudeUsageSnapshot(nil)
        }
        if let snapshotPath = ProcessInfo.processInfo.environment["TMUXPAL_SNAPSHOT_PATH"] {
            overlayView.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
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

enum UsageRingDisplayMode: String, CaseIterable {
    case off
    case rings
    case labeled

    var menuTitle: String {
        switch self {
        case .off: return "Off"
        case .rings: return "Rings Only"
        case .labeled: return "With Labels"
        }
    }
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
    static let usageRingLabelOutset: CGFloat = 58
    static let usageRingModeDefaultsKey = "codexUsageRingMode"

    var onDrag: ((_ screenPoint: CGPoint, _ palGrabOffset: CGPoint, _ horizontalDelta: CGFloat) -> Void)?
    var onClickPane: ((TmuxPane) -> Void)?
    var onCollapseChanged: (() -> Void)?
    /// Fired when a pane finishes a run that nobody has acknowledged yet, so
    /// the controller can raise the overlay window once.
    var onAttentionRaised: (() -> Void)?

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
    private var highlightedPaneId: String?
    private var manuallyHighlightedPaneId: String?
    private var acknowledgedPaneIds: Set<String> = []
    private var bubbleHorizontalSide: BubbleHorizontalSide = .left
    private var bubbleVerticalSide: BubbleVerticalSide = .above
    private(set) var showsBubbleUI = true
    private(set) var usageRingMode = UsageRingDisplayMode(
        rawValue: UserDefaults.standard.string(forKey: usageRingModeDefaultsKey) ?? ""
    ) ?? .rings
    var showsUsageRings: Bool {
        usageRingMode != .off
    }
    private var usageSnapshot: CodexUsageSnapshot?
    private var claudeUsageSnapshot: ClaudeUsageSnapshot?
    private var usageRingPalette = UsageRingPalette.default
    private let claudeRingPalette = UsageRingPalette.derived(from: UsageRingPalette.claudeBase)

    init(frame frameRect: NSRect = .zero, palAssetConfig: PalAssetConfig) {
        self.palAssetConfig = palAssetConfig
        super.init(frame: frameRect)
        wantsLayer = false
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
            return NSSize(
                width: palSize.width + Self.padding * 2 + usageRingLabelWidth,
                height: palSize.height + Self.padding * 2
            )
        }
        var size = Self.size(
            forBubbleCount: max(1, bubbles.count),
            collapsed: isCollapsed,
            palSize: palSize,
            bubbleVerticalSide: bubbleVerticalSide
        )
        if isCollapsed {
            size.width += usageRingLabelWidth
        }
        return size
    }

    private var usageRingLabelWidth: CGFloat {
        usageRingMode == .labeled ? Self.usageRingLabelOutset : 0
    }

    func updateBubbleLayout(palCenter: CGPoint, visibleFrame: NSRect) {
        guard showsBubbleUI, !isCollapsed else { return }
        let count = max(1, bubbles.count)
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
        let loader = PalSpriteLoader(config: palAssetConfig)
        framesByState = loader.loadFrames()
        usageRingPalette = UsageRingPalette.derived(from: loader.dominantColor())
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

    func setUsageRingMode(_ usageRingMode: UsageRingDisplayMode) {
        self.usageRingMode = usageRingMode
        UserDefaults.standard.set(usageRingMode.rawValue, forKey: Self.usageRingModeDefaultsKey)
        needsDisplay = true
    }

    func setUsageSnapshot(_ snapshot: CodexUsageSnapshot?) {
        usageSnapshot = snapshot?.hasVisibleBuckets == true ? snapshot : nil
        needsDisplay = true
    }

    func setClaudeUsageSnapshot(_ snapshot: ClaudeUsageSnapshot?) {
        claudeUsageSnapshot = snapshot?.hasVisibleBuckets == true ? snapshot : nil
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
        let previousRunStates = runStatesByPaneId
        let nextRunStates = Dictionary(uniqueKeysWithValues: self.bubbles.map { bubble in
            (bubble.pane.paneId, runClassifier.classify(bubble))
        })
        runStatesByPaneId = nextRunStates
        for (paneId, state) in nextRunStates where state == .running && previousRunStates[paneId] != .running {
            acknowledgedPaneIds.remove(paneId)
        }
        let paneIds = Set(self.bubbles.map { $0.pane.paneId })
        acknowledgedPaneIds.formIntersection(paneIds)
        updateHighlightedPaneId()
        for bubble in self.bubbles where bubble.pane.active && runState(for: bubble) != .running {
            acknowledgedPaneIds.insert(bubble.pane.paneId)
        }
        completedBubbleCount = runStatesByPaneId.values.filter { $0 == .complete }.count
        let hasNewUnacknowledgedCompletion = nextRunStates.contains { paneId, state in
            state == .complete
                && previousRunStates[paneId] == .running
                && !acknowledgedPaneIds.contains(paneId)
        }
        if hasNewUnacknowledgedCompletion {
            onAttentionRaised?()
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

    func setHighlightedPaneId(_ paneId: String, manual: Bool) {
        highlightedPaneId = paneId
        acknowledgedPaneIds.insert(paneId)
        if manual {
            manuallyHighlightedPaneId = paneId
        }
        needsDisplay = true
    }

    private func updateHighlightedPaneId() {
        let paneIds = Set(bubbles.map { $0.pane.paneId })
        if let manual = manuallyHighlightedPaneId, paneIds.contains(manual) {
            highlightedPaneId = manual
            return
        }
        manuallyHighlightedPaneId = nil
        highlightedPaneId = bubbles.first(where: { $0.pane.active })?.pane.paneId
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
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        super.draw(dirtyRect)
        if dirtyRect.intersects(palRect()) {
            drawUsageRings()
            drawUsageRingLabels()
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

    private func drawUsageRings() {
        guard showsUsageRings else { return }
        let rings = usageRings()
        guard !rings.isEmpty else { return }
        for ring in rings {
            drawUsageRing(
                center: ring.center,
                radius: ring.radius,
                lineWidth: ring.lineWidth,
                bucket: ring.bucket,
                color: ring.color
            )
        }
        clearUsageRingGap(rings: rings)
        for ring in rings {
            drawUsagePaceMarker(ring: ring)
        }
    }

    private func drawUsageRingLabels() {
        guard usageRingMode == .labeled, showsUsageRings else { return }
        for ring in usageRings() {
            drawUsageRingTag(ring.label, bucket: ring.bucket, center: ring.center, radius: ring.radius, color: ring.color, yOffset: ring.labelYOffset)
            drawUsageRingEndDot(center: ring.center, radius: ring.radius, lineWidth: ring.lineWidth, bucket: ring.bucket, color: ring.color)
        }
    }

    private struct DrawableUsageRing {
        let label: String
        let bucket: CodexUsageBucket
        let color: NSColor
        let observedAt: Date
        let center: CGPoint
        let radius: CGFloat
        let lineWidth: CGFloat
        let labelYOffset: CGFloat
    }

    private struct UsageRingSpec {
        let label: String
        let bucket: CodexUsageBucket
        let color: NSColor
        let observedAt: Date
    }

    /// Claude rings sit on the outside, Codex rings on the inside.
    private func usageRingSpecs() -> [UsageRingSpec] {
        var specs: [UsageRingSpec] = []
        if let claudeUsageSnapshot {
            if let sevenDay = claudeUsageSnapshot.sevenDay {
                specs.append(UsageRingSpec(
                    label: sevenDay.label,
                    bucket: sevenDay,
                    color: claudeRingPalette.weekly,
                    observedAt: claudeUsageSnapshot.observedAt
                ))
            }
            if let fiveHour = claudeUsageSnapshot.fiveHour {
                specs.append(UsageRingSpec(
                    label: fiveHour.label,
                    bucket: fiveHour,
                    color: claudeRingPalette.shortTerm,
                    observedAt: claudeUsageSnapshot.observedAt
                ))
            }
        }
        if let usageSnapshot {
            if let monthly = usageSnapshot.monthly {
                specs.append(UsageRingSpec(
                    label: "M",
                    bucket: monthly,
                    color: usageRingPalette.monthly,
                    observedAt: usageSnapshot.observedAt
                ))
            }
            if let weekly = usageSnapshot.weekly {
                specs.append(UsageRingSpec(
                    label: "W",
                    bucket: weekly,
                    color: usageRingPalette.weekly,
                    observedAt: usageSnapshot.observedAt
                ))
            }
            if let shortTerm = usageSnapshot.shortTerm {
                specs.append(UsageRingSpec(
                    label: shortTerm.label,
                    bucket: shortTerm,
                    color: usageRingPalette.shortTerm,
                    observedAt: usageSnapshot.observedAt
                ))
            }
        }
        return specs
    }

    private func usageRings() -> [DrawableUsageRing] {
        let specs = usageRingSpecs()
        guard !specs.isEmpty else { return [] }
        let rect = palRect()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        let count = CGFloat(specs.count)
        return specs.enumerated().map { index, spec in
            let depth = CGFloat(index)
            return DrawableUsageRing(
                label: spec.label,
                bucket: spec.bucket,
                color: spec.color,
                observedAt: spec.observedAt,
                center: center,
                radius: baseRadius - 0.5 - 5.5 * depth,
                lineWidth: max(2.6, 3.8 - 0.3 * depth),
                labelYOffset: 14.0 * (count / 2 - depth - 0.5)
            )
        }
    }

    private func drawUsageRing(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, bucket: CodexUsageBucket, color: NSColor) {
        drawUsageRingTrack(center: center, radius: radius, lineWidth: lineWidth)
        guard bucket.remainingPercent > 0.1 else { return }
        let startAngle: CGFloat = 247.5
        let sweep: CGFloat = 315
        let foreground = NSBezierPath()
        foreground.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle - sweep * CGFloat(bucket.remainingPercent / 100.0),
            clockwise: true
        )
        color.withAlphaComponent(0.96).setStroke()
        foreground.lineWidth = lineWidth
        foreground.lineCapStyle = .round
        foreground.stroke()
    }

    private func drawUsageRingTrack(center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 247.5,
            endAngle: -67.5,
            clockwise: true
        )
        NSColor(calibratedWhite: 0.68, alpha: 0.34).setStroke()
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        track.stroke()
    }

    private func drawUsagePaceMarker(ring: DrawableUsageRing) {
        guard let paceRemaining = ring.bucket.paceRemainingPercent(at: ring.observedAt) else { return }
        let angle = usageRingAngle(forRemainingPercent: paceRemaining)
        let innerRadius = ring.radius - ring.lineWidth * 0.78
        let outerRadius = ring.radius + ring.lineWidth * 0.78
        let inner = CGPoint(
            x: ring.center.x + cos(angle) * innerRadius,
            y: ring.center.y + sin(angle) * innerRadius
        )
        let outer = CGPoint(
            x: ring.center.x + cos(angle) * outerRadius,
            y: ring.center.y + sin(angle) * outerRadius
        )
        let backing = NSBezierPath()
        backing.move(to: inner)
        backing.line(to: outer)
        NSColor.white.withAlphaComponent(0.82).setStroke()
        backing.lineWidth = max(1.8, ring.lineWidth * 0.68)
        backing.lineCapStyle = .round
        backing.stroke()

        let marker = NSBezierPath()
        marker.move(to: inner)
        marker.line(to: outer)
        NSColor.black.withAlphaComponent(0.72).setStroke()
        marker.lineWidth = max(1.0, ring.lineWidth * 0.36)
        marker.lineCapStyle = .round
        marker.stroke()
    }

    private func usageRingAngle(forRemainingPercent remainingPercent: Double) -> CGFloat {
        let clamped = min(max(remainingPercent, 0.0), 100.0)
        return (247.5 - 315 * CGFloat(clamped / 100.0)) * .pi / 180.0
    }

    private func clearUsageRingGap(rings: [DrawableUsageRing]) {
        guard let context = NSGraphicsContext.current?.cgContext, !rings.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        for ring in rings {
            let gap = NSBezierPath()
            gap.appendArc(withCenter: ring.center, radius: ring.radius, startAngle: 247.5, endAngle: 292.5, clockwise: false)
            gap.lineWidth = ring.lineWidth + 3.5
            gap.lineCapStyle = .butt
            gap.stroke()
        }
        context.restoreGState()
    }

    private func drawUsageRingEndDot(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, bucket: CodexUsageBucket, color: NSColor) {
        guard bucket.remainingPercent > 0.1 else { return }
        let angle = usageRingAngle(forRemainingPercent: bucket.remainingPercent)
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let dotSize = max(3.0, lineWidth + 0.8)
        let dotRect = NSRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2, width: dotSize, height: dotSize)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    private func drawUsageRingTag(_ label: String, bucket: CodexUsageBucket, center: CGPoint, radius: CGFloat, color: NSColor, yOffset: CGFloat) {
        let text = "\(label.replacingOccurrences(of: " ", with: "")) \(Int(round(bucket.remainingPercent)))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = NSString(string: text).size(withAttributes: attrs)
        let padding = NSSize(width: 5, height: 2.5)
        let tagRect = NSRect(
            x: center.x - radius - textSize.width - padding.width * 2 - 7,
            y: center.y + yOffset,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let background = NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5)
        color.withAlphaComponent(0.96).setFill()
        background.fill()
        NSString(string: text).draw(
            at: CGPoint(x: tagRect.minX + padding.width, y: tagRect.minY + padding.height - 0.5),
            withAttributes: attrs
        )
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
        let visibleBubbles = bubbles.isEmpty ? [placeholderBubble()] : bubbles
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
            drawStatus(in: statusRect, bubble: bubble)
            return
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        if isHighlighted(bubble) {
            NSColor(calibratedRed: 0.92, green: 1.0, blue: 0.94, alpha: 0.96).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.92).setFill()
        }
        path.fill()
        if isHighlighted(bubble) {
            NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.38, alpha: 0.34).setStroke()
        } else {
            NSColor.black.withAlphaComponent(0.10).setStroke()
        }
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
        let bubbleDensity = Self.density(for: max(1, bubbles.count))
        drawStatus(in: statusRect, bubble: bubble)

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

    private func drawStatus(in rect: NSRect, bubble: PaneBubble) {
        let state = runState(for: bubble)
        let path = NSBezierPath(ovalIn: rect)
        let green = NSColor(calibratedRed: 0.02, green: 0.72, blue: 0.28, alpha: 1)
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
        if isAcknowledged(bubble) {
            green.setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            NSString(string: "✓").draw(in: rect.insetBy(dx: 3.2, dy: 0.9), withAttributes: attrs)
            return
        }

        let dotRect = rect.insetBy(dx: 3.5, dy: 3.5)
        green.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
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
        return PaneBubble(pane: pane, summary: "Waiting for tmux AI panes")
    }

    private func palRect() -> NSRect {
        palRect(in: bounds)
    }

    private func palRect(in bounds: NSRect) -> NSRect {
        let size = palSize
        if !showsBubbleUI {
            return NSRect(x: Self.padding + usageRingLabelWidth, y: Self.padding, width: size.width, height: size.height)
        }
        if isCollapsed {
            return NSRect(x: Self.padding + usageRingLabelWidth, y: Self.padding, width: size.width, height: size.height)
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

    private func isHighlighted(_ bubble: PaneBubble) -> Bool {
        highlightedPaneId == bubble.pane.paneId
    }

    private func isAcknowledged(_ bubble: PaneBubble) -> Bool {
        acknowledgedPaneIds.contains(bubble.pane.paneId)
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
    static func activatePreferredTerminal(for pane: TmuxPane? = nil) {
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
            let name = preferred.localizedName?.lowercased() ?? ""
            let bundleId = preferred.bundleIdentifier?.lowercased() ?? ""
            if name.contains("ghostty") || bundleId.contains("ghostty") {
                if activateGhosttyByAppleScript(tabPrefix: ghosttyTabPrefix(for: pane)) {
                    return
                }
            }
            preferred.activate(options: [])
        }
    }

    private static func ghosttyTabPrefix(for pane: TmuxPane?) -> String? {
        guard let pane else {
            return nil
        }
        return pane.sessionName == TmuxCollector.herdrSessionName ? "herdr" : "tmux"
    }

    private static func activateGhosttyByAppleScript(tabPrefix: String?) -> Bool {
        var error: NSDictionary?
        let script: String
        if let tabPrefix {
            script = """
            tell application "Ghostty"
                set targetWindowId to missing value
                set targetTabId to missing value
                repeat with ghosttyWindow in windows
                    repeat with ghosttyTab in tabs of ghosttyWindow
                        if name of ghosttyTab starts with "\(tabPrefix)" then
                            set targetWindowId to id of ghosttyWindow as text
                            set targetTabId to id of ghosttyTab as text
                            exit repeat
                        end if
                    end repeat
                    if targetWindowId is not missing value then exit repeat
                end repeat
                if targetWindowId is not missing value then
                    set targetWindow to first window whose id is targetWindowId
                    set targetTab to first tab of targetWindow whose id is targetTabId
                    select tab targetTab
                    activate window targetWindow
                    return true
                end if
            end tell
            return false
            """
        } else {
            script = #"tell application "Ghostty" to activate"#
        }
        if runOsaScript(script) {
            return true
        }
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            DebugLog.write("ghostty tab activation failed: \(error)")
            return false
        }
        return true
    }

    private static func runOsaScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { ["-e", String($0)] }
        process.standardOutput = Pipe()
        let error = Pipe()
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let outputData = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return output != "false"
            }
            let data = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "osascript failed"
            DebugLog.write("ghostty tab osascript failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        } catch {
            DebugLog.write("ghostty tab osascript failed: \(error.localizedDescription)")
            return false
        }
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

    func dominantColor() -> NSColor {
        guard let sheet = NSImage(contentsOf: config.spritesheetURL),
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = Self.rgbaContext(width: cgImage.width, height: cgImage.height) else {
            return UsageRingPalette.defaultBase
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let raw = context.data else {
            return UsageRingPalette.defaultBase
        }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: cgImage.width * cgImage.height * 4)
        let bytesPerPixel = 4
        let bytesPerRow = context.bytesPerRow
        let width = cgImage.width
        let height = cgImage.height
        var preferredBuckets: [String: (red: CGFloat, green: CGFloat, blue: CGFloat, count: Int)] = [:]
        var fallbackBuckets: [String: (red: CGFloat, green: CGFloat, blue: CGFloat, count: Int)] = [:]
        let step = max(8, min(width, height) / 90)

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard bytesPerPixel >= 4 else { continue }
                let red = CGFloat(bytes[offset]) / 255.0
                let green = CGFloat(bytes[offset + 1]) / 255.0
                let blue = CGFloat(bytes[offset + 2]) / 255.0
                let alpha = CGFloat(bytes[offset + 3]) / 255.0
                guard alpha > 0.35 else { continue }
                let maxComponent = max(red, green, blue)
                let minComponent = min(red, green, blue)
                let saturation = maxComponent == 0 ? 0 : (maxComponent - minComponent) / maxComponent
                guard saturation > 0.16, maxComponent > 0.20, maxComponent < 0.96 else { continue }
                Self.addSample(red: red, green: green, blue: blue, to: &fallbackBuckets)
                if !Self.isLikelyHumanTone(red: red, green: green, blue: blue, saturation: saturation, brightness: maxComponent) {
                    Self.addSample(red: red, green: green, blue: blue, to: &preferredBuckets)
                }
            }
        }

        let buckets = preferredBuckets.isEmpty ? fallbackBuckets : preferredBuckets
        guard let dominant = buckets.values.max(by: { $0.count < $1.count }), dominant.count > 0 else {
            return UsageRingPalette.defaultBase
        }
        return NSColor(
            calibratedRed: dominant.red / CGFloat(dominant.count),
            green: dominant.green / CGFloat(dominant.count),
            blue: dominant.blue / CGFloat(dominant.count),
            alpha: 1.0
        )
    }

    private static func addSample(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        to buckets: inout [String: (red: CGFloat, green: CGFloat, blue: CGFloat, count: Int)]
    ) {
        let key = "\(Int(red * 5))-\(Int(green * 5))-\(Int(blue * 5))"
        let current = buckets[key] ?? (0, 0, 0, 0)
        buckets[key] = (
            current.red + red,
            current.green + green,
            current.blue + blue,
            current.count + 1
        )
    }

    private static func isLikelyHumanTone(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> Bool {
        let hue = hue(red: red, green: green, blue: blue)
        let warmHue = hue <= 0.13 || hue >= 0.97
        let humanWarmRamp = warmHue
            && red >= green
            && green >= blue
            && saturation >= 0.12
            && saturation <= 0.82
            && brightness >= 0.16
            && brightness <= 0.96
        return humanWarmRamp
    }

    private static func hue(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent
        guard delta > 0 else { return 0 }
        let rawHue: CGFloat
        if maxComponent == red {
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxComponent == green {
            rawHue = (blue - red) / delta + 2
        } else {
            rawHue = (red - green) / delta + 4
        }
        let normalized = rawHue / 6
        return normalized < 0 ? normalized + 1 : normalized
    }

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

struct UsageRingPalette {
    static let defaultBase = NSColor(calibratedRed: 0.18, green: 0.70, blue: 0.58, alpha: 1)
    // Anthropic brand coral (#D97757) so Claude rings read distinctly from
    // the pal-derived Codex rings.
    static let claudeBase = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let `default` = UsageRingPalette.derived(from: defaultBase)

    let outer: NSColor
    let weekly: NSColor
    let monthly: NSColor
    let shortTerm: NSColor

    static func derived(from color: NSColor) -> UsageRingPalette {
        let rgb = color.usingColorSpace(.deviceRGB) ?? defaultBase
        let hue = rgb.hueComponent
        let saturation = min(max(rgb.saturationComponent, 0.34), 0.86)
        let brightness = min(max(rgb.brightnessComponent, 0.40), 0.86)
        return UsageRingPalette(
            outer: NSColor(
                calibratedHue: hue,
                saturation: min(0.92, max(0.58, saturation * 1.08)),
                brightness: min(0.70, max(0.50, brightness * 0.72)),
                alpha: 1.0
            ),
            weekly: NSColor(
                calibratedHue: hue,
                saturation: min(0.82, max(0.42, saturation * 0.78)),
                brightness: min(0.88, max(0.66, brightness * 1.08)),
                alpha: 1.0
            ),
            monthly: NSColor(
                calibratedHue: hue,
                saturation: min(0.92, max(0.58, saturation * 1.08)),
                brightness: min(0.70, max(0.50, brightness * 0.72)),
                alpha: 1.0
            ),
            shortTerm: NSColor(
                calibratedHue: hue,
                saturation: min(0.64, max(0.30, saturation * 0.52)),
                brightness: 0.96,
                alpha: 1.0
            )
        )
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
