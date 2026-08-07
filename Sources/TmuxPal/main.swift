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

func outputURL(for option: String) -> URL? {
    guard let index = CommandLine.arguments.firstIndex(of: option) else {
        return nil
    }
    guard CommandLine.arguments.indices.contains(index + 1) else {
        fputs("\(option) requires an output path\n", stderr)
        Foundation.exit(2)
    }
    return URL(fileURLWithPath: CommandLine.arguments[index + 1])
}

let statusBarOutputURL = outputURL(for: "--dump-status-bar-image")
let overlayOutputURL = outputURL(for: "--dump-overlay-image")
if statusBarOutputURL != nil || overlayOutputURL != nil {
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        let result = await UsageImageExporter.export(
            statusBarURL: statusBarOutputURL,
            overlayURL: overlayOutputURL
        )
        let labelBoundsFit = result.overlaySize.map { size in
            let bounds = NSRect(origin: .zero, size: size)
            return result.overlayLabelBounds.allSatisfy { bounds.contains($0.rect) }
        } ?? true
        for bound in result.overlayLabelBounds {
            print("overlay-label\t\(bound.label)\t\(NSStringFromRect(bound.rect))")
        }
        print("status-bar-written=\(result.statusBarWritten)")
        print("overlay-written=\(result.overlayWritten)")
        print("overlay-labels-fit=\(labelBoundsFit)")
        Foundation.exit(result.statusBarWritten && result.overlayWritten && labelBoundsFit ? 0 : 1)
    }
    previewApp.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated {
    AppDelegate()
}
app.delegate = delegate
app.run()
