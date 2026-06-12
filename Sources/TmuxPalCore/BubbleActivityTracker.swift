import Foundation

/// Decides whether the overlay has "activity" worth expanding the bubble UI
/// for. Activity means a pane is currently running, or a pane finished a run
/// (running -> complete transition) and the user has not acknowledged it yet.
/// Panes that were already complete when first observed never count, so a
/// quiet launch stays collapsed.
public struct BubbleActivityTracker: Sendable {
    private var previousRunStates: [String: BubbleRunState] = [:]
    private var attentionPaneIds: Set<String> = []

    public init() {}

    public var hasActivity: Bool {
        previousRunStates.values.contains(.running) || !attentionPaneIds.isEmpty
    }

    @discardableResult
    public mutating func update(
        runStates: [String: BubbleRunState],
        acknowledgedPaneIds: Set<String>
    ) -> Bool {
        for (paneId, state) in runStates
        where state == .complete && previousRunStates[paneId] == .running {
            attentionPaneIds.insert(paneId)
        }
        attentionPaneIds.formIntersection(runStates.keys)
        attentionPaneIds.subtract(acknowledgedPaneIds)
        previousRunStates = runStates
        return hasActivity
    }

    @discardableResult
    public mutating func acknowledge(paneId: String) -> Bool {
        attentionPaneIds.remove(paneId)
        return hasActivity
    }
}
