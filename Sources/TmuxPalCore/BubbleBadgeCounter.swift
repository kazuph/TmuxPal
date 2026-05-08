import Foundation

public struct BubbleBadgeCounter: Sendable {
    private let classifier: BubbleRunClassifier

    public init(classifier: BubbleRunClassifier = BubbleRunClassifier()) {
        self.classifier = classifier
    }

    public func completedAwaitingCount(in bubbles: [PaneBubble]) -> Int {
        bubbles.filter { classifier.classify($0) == .complete }.count
    }
}
