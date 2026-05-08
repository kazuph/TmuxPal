import AppKit
import Foundation
import TmuxPalCore

if CommandLine.arguments.contains("--dump-panes") {
    let panes = (try? TmuxCollector().collect()) ?? []
    for pane in panes {
        print("\(pane.tool.displayName)\t\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)\t\(pane.paneId)\t\(pane.currentCommand)\t\(pane.currentPath)\t\(pane.title)")
    }
    Foundation.exit(panes.isEmpty ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
