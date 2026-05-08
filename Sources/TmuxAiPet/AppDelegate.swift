import AppKit
import Foundation
import TmuxAiPetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayController: OverlayController?
    private var appServerManager: AppServerManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? AppSupport.ensureSupportDirectory()
        DebugLog.write("app launched")

        let overlayController = OverlayController()
        self.overlayController = overlayController
        overlayController.show()

        let appServerManager = AppServerManager()
        self.appServerManager = appServerManager
        appServerManager.startIfAvailable()

        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("app terminating")
        appServerManager?.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "pet"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "表示/非表示", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "再読み込み", action: #selector(reloadOverlay), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleOverlay() {
        overlayController?.toggle()
    }

    @objc private func reloadOverlay() {
        overlayController?.reloadNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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

    init() {
        overlayView = OverlayView()
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
        overlayView.onCollapseChanged = { [weak self] petCenter in
            self?.fitWindow(keepingPetCenter: petCenter)
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
        overlayView.reloadPetAssets()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
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
        if let snapshotPath = ProcessInfo.processInfo.environment["TMUX_AI_PET_SNAPSHOT_PATH"] {
            overlayView.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }
        if lastLoggedBubbleCount != bubbles.count {
            DebugLog.write("updated panes=\(paneCount) bubbles=\(bubbles.count) frame=\(NSStringFromRect(window.frame))")
            lastLoggedBubbleCount = bubbles.count
        }
    }

    private func fitWindow() {
        fitWindow(keepingPetCenter: petScreenCenter())
    }

    private func fitWindow(keepingPetCenter petCenter: CGPoint) {
        updateBubbleLayout(forPetCenter: petCenter)
        applyPreferredFrame(keepingPetCenter: petCenter)
        clampToVisibleScreen()
        let visiblePetCenter = petScreenCenter()
        updateBubbleLayout(forPetCenter: visiblePetCenter)
        applyPreferredFrame(keepingPetCenter: visiblePetCenter)
        clampToVisibleScreen()
    }

    private func moveWindow(toScreenPoint screenPoint: CGPoint, grabOffset: CGPoint, horizontalDelta: CGFloat) {
        var frame = window.frame
        frame.origin.x = screenPoint.x - grabOffset.x
        frame.origin.y = screenPoint.y - grabOffset.y
        window.setFrame(frame, display: true)
        updateBubbleLayout()
        applyPreferredFrame(keepingPetCenter: petScreenCenter())
        clampToVisibleScreen()
        overlayView.setDragging(horizontalDelta: horizontalDelta)
        saveFrame()
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "overlayFrame")
    }

    @objc private func screenParametersDidChange() {
        clampToVisibleScreen()
        saveFrame()
    }

    private func clampToVisibleScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(petScreenCenter()) }) ?? NSScreen.main else {
            return
        }
        var frame = window.frame
        let visible = screen.visibleFrame
        let pet = overlayView.petRectInBounds()
        let petScreen = pet.offsetBy(dx: frame.minX, dy: frame.minY)
        if petScreen.minX < visible.minX {
            frame.origin.x += visible.minX - petScreen.minX
        }
        if petScreen.maxX > visible.maxX {
            frame.origin.x -= petScreen.maxX - visible.maxX
        }
        if petScreen.minY < visible.minY {
            frame.origin.y += visible.minY - petScreen.minY
        }
        if petScreen.maxY > visible.maxY {
            frame.origin.y -= petScreen.maxY - visible.maxY
        }
        window.setFrame(frame, display: true)
    }

    private func applyPreferredFrame(keepingPetCenter petCenter: CGPoint) {
        let desired = overlayView.preferredSize()
        var frame = window.frame
        frame.size = desired
        frame.origin.x = petCenter.x - overlayView.petCenterInBounds().x
        frame.origin.y = petCenter.y - overlayView.petCenterInBounds().y
        window.setFrame(frame, display: true)
    }

    private func updateBubbleLayout() {
        updateBubbleLayout(forPetCenter: petScreenCenter())
    }

    private func updateBubbleLayout(forPetCenter petCenter: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(petCenter) }) ?? NSScreen.main else {
            return
        }
        overlayView.updateBubbleLayout(petCenter: petCenter, visibleFrame: screen.visibleFrame)
    }

    private func petScreenCenter() -> CGPoint {
        let pet = overlayView.petRectInBounds()
        return CGPoint(x: window.frame.minX + pet.midX, y: window.frame.minY + pet.midY)
    }

    private static func savedFrame() -> NSRect {
        if ProcessInfo.processInfo.environment["TMUX_AI_PET_RESET_POSITION"] == "1" {
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
    static let petSize = NSSize(width: 77, height: 85)
    static let bubbleWidth: CGFloat = 280
    static let bubbleHeight: CGFloat = 76
    static let padding: CGFloat = 14
    static let bubblePetGap: CGFloat = 18

    var onDrag: ((_ screenPoint: CGPoint, _ grabOffset: CGPoint, _ horizontalDelta: CGFloat) -> Void)?
    var onClickPane: ((TmuxPane) -> Void)?
    var onCollapseChanged: ((CGPoint) -> Void)?

    private var bubbles: [PaneBubble] = []
    private var bubbleRects: [(NSRect, TmuxPane)] = []
    private var lastDragScreenPoint: NSPoint?
    private var dragGrabOffset: CGPoint?
    private var didDrag = false
    private var dragResetTimer: Timer?
    private var isHovering = false
    private var isDragging = false
    private var isCollapsed = ProcessInfo.processInfo.environment["TMUX_AI_PET_COLLAPSED"] == "1"
        || UserDefaults.standard.bool(forKey: "bubblesCollapsed")
    private var animationState = "idle"
    private var lastHorizontalDragState = "running-right"
    private var frameIndex = 0
    private var framesByState: [String: [PetFrame]] = [:]
    private var animationTimer: Timer?
    private let runClassifier = BubbleRunClassifier()
    private var bubbleHorizontalSide: BubbleHorizontalSide = .left
    private var bubbleVerticalSide: BubbleVerticalSide = .above

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        reloadPetAssets()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in
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

    static func size(forBubbleCount count: Int, collapsed: Bool) -> NSSize {
        if collapsed {
            return NSSize(width: petSize.width + padding * 2, height: petSize.height + padding * 2)
        }
        let bubbleStackHeight = Self.bubbleStackHeight(for: count)
        let height = petSize.height + bubbleStackHeight + padding * 2 + bubblePetGap
        return NSSize(width: bubbleWidth + padding * 2, height: height)
    }

    static func bubbleStackHeight(for count: Int) -> CGFloat {
        CGFloat(count) * bubbleHeight + CGFloat(max(0, count - 1)) * 8
    }

    func preferredSize() -> NSSize {
        Self.size(forBubbleCount: max(1, min(6, bubbles.count)), collapsed: isCollapsed)
    }

    func updateBubbleLayout(petCenter: CGPoint, visibleFrame: NSRect) {
        guard !isCollapsed else { return }
        let count = max(1, min(6, bubbles.count))
        let stackHeight = Self.bubbleStackHeight(for: count)
        let requiredHorizontal = Self.bubbleWidth + Self.padding * 2
        let requiredVertical = stackHeight + Self.padding
        bubbleHorizontalSide = petCenter.x - Self.petSize.width / 2 - requiredHorizontal < visibleFrame.minX ? .right : .left
        bubbleVerticalSide = petCenter.y + Self.petSize.height / 2 + requiredVertical > visibleFrame.maxY ? .below : .above
        if petCenter.y - Self.petSize.height / 2 - requiredVertical < visibleFrame.minY {
            bubbleVerticalSide = .above
        }
        needsDisplay = true
    }

    func petRectInBounds() -> NSRect {
        petRect()
    }

    func petCenterInBounds() -> CGPoint {
        let pet = petRect()
        return CGPoint(x: pet.midX, y: pet.midY)
    }

    func reloadPetAssets() {
        framesByState = PetSpriteLoader(config: PetAssetConfig()).loadFrames()
        DebugLog.write("pet assets loaded states=\(framesByState.keys.sorted().joined(separator: ","))")
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
        drawPet()
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

    private func drawPet() {
        let petRect = petRect()
        let frames = framesByState[animationState] ?? framesByState["idle"] ?? []
        if let frame = frames.isEmpty ? nil : frames[frameIndex % frames.count] {
            frame.draw(in: petRect)
        } else {
            NSColor.systemGreen.withAlphaComponent(0.25).setFill()
            petRect.fill()
        }
    }

    private func drawBubbles() {
        bubbleRects.removeAll()
        let visibleBubbles = bubbles.isEmpty ? [placeholderBubble()] : Array(bubbles.prefix(6))
        let pet = petRect()
        let startX = bubbleHorizontalSide == .left
            ? pet.maxX - Self.bubbleWidth
            : pet.minX
        var y: CGFloat
        if bubbleVerticalSide == .above {
            y = pet.maxY + Self.bubblePetGap + Self.bubbleStackHeight(for: visibleBubbles.count) - Self.bubbleHeight
        } else {
            y = pet.minY - Self.bubblePetGap - Self.bubbleHeight
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
        let count = runningTaskCount()
        let pet = petRect()
        let badgeSize: CGFloat = 28
        let rect = NSRect(
            x: pet.midX + Self.petSize.width * 0.04,
            y: pet.midY + Self.petSize.height * 0.10,
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

    private func petRect() -> NSRect {
        if isCollapsed {
            return NSRect(x: Self.padding, y: Self.padding, width: Self.petSize.width, height: Self.petSize.height)
        }
        let x = bubbleHorizontalSide == .left
            ? bounds.width - Self.padding - Self.petSize.width
            : Self.padding
        let y = bubbleVerticalSide == .above
            ? Self.padding
            : bounds.height - Self.padding - Self.petSize.height
        return NSRect(x: x, y: y, width: Self.petSize.width, height: Self.petSize.height)
    }

    private func toggleCollapsed() {
        guard let window else { return }
        let pet = petRect()
        let screenPetCenter = CGPoint(x: window.frame.minX + pet.midX, y: window.frame.minY + pet.midY)
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: "bubblesCollapsed")
        bubbleRects.removeAll()
        needsDisplay = true
        onCollapseChanged?(screenPetCenter)
    }

    private func runningTaskCount() -> Int {
        bubbles.filter { runState(for: $0) == .running }.count
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
        if !didDrag, petRect().contains(point) {
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

struct PetFrame {
    let image: NSImage

    func draw(in rect: NSRect) {
        image.draw(in: rect)
    }
}

struct PetSpriteLoader {
    let config: PetAssetConfig
    let cellWidth: CGFloat = 192
    let cellHeight: CGFloat = 208

    func loadFrames() -> [String: [PetFrame]] {
        DebugLog.write("loading pet spritesheet=\(config.spritesheetURL.path)")
        guard let sheet = NSImage(contentsOf: config.spritesheetURL),
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [:]
        }

        var result: [String: [PetFrame]] = [:]
        for row in config.loadRows() {
            var frames: [PetFrame] = []
            for frame in 0..<row.frames {
                let crop = CGRect(x: CGFloat(frame) * cellWidth, y: CGFloat(row.row) * cellHeight, width: cellWidth, height: cellHeight)
                if let cropped = cgImage.cropping(to: crop) {
                    let image = NSImage(cgImage: cropped, size: NSSize(width: cellWidth, height: cellHeight))
                    frames.append(PetFrame(image: image))
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
            "/Users/kazuph/.local/share/mise/installs/node/22.21.1/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
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
}

enum DebugLog {
    private static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tmux-ai-pet.debug.log")

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
