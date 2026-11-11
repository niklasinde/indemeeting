import Foundation

/// Where the pull request's Agent or Claude terminal sits next to the page, and how big it is. Pure, so the rule is tested without
/// a window; TerminalSplit and GitHubView lay it out.
enum DockPlacement {
    static let choiceKey = "embeddedTerminalPlacement"
    static let rightSizeKey = "embeddedTerminalRightWidth"
    static let belowSizeKey = "embeddedTerminalBelowHeight"

    /// What is picked in the pane's header.
    enum Choice: String, CaseIterable, Identifiable {
        case automatic, right, below, bottom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .right: return "Right"
            case .below: return "Below"
            case .bottom: return "Bottom, Full Width"
            }
        }

        var symbol: String {
            switch self {
            case .automatic: return "rectangle.3.group"
            case .right: return "sidebar.right"
            case .below: return "rectangle.bottomthird.inset.filled"
            case .bottom: return "rectangle.bottomhalf.inset.filled"
            }
        }
    }

    /// Beside the page, under the page, or across the bottom of the whole window under the list too.
    enum Placement: Equatable { case right, below, bottom }

    static let rightRange = 360.0...900.0
    static let belowRange = 220.0...1000.0
    static let minimumPageWidth = 480.0
    static let minimumPageHeight = 200.0
    /// The handle between the page and the pane, which takes a point of the room too.
    static let handleLength = 1.0
    static let defaultRight = 480.0
    /// Zero means half the available height, which is the default bottom half.
    static let defaultBelow = 0.0
    /// Automatic puts the pane beside the page when the page keeps this much next to a pane of `autoPaneWidth`.
    static let autoPageWidth = 500.0
    static let autoPaneWidth = 400.0
    /// Automatic spans the bottom of windows at least this tall when the pane does not fit beside the page.
    static let bottomFromHeight = 900.0

    /// The detail area width from which Automatic goes right: a 1530 point window with the app sidebar and the 420 point list
    /// leaves about 913 for it.
    static var autoRightFrom: Double { autoPageWidth + handleLength + autoPaneWidth }
    /// The narrowest detail area that holds the page and the pane at their minimums side by side.
    static var rightFitsFrom: Double { minimumPageWidth + handleLength + rightRange.lowerBound }

    /// Where the pane goes for the choice in a detail area `detailWidth` wide, in a window `windowHeight` tall. `canSpan` is
    /// false when there is no list beside the page, so the bottom is the same as below. Right falls back to below when the page
    /// and the pane do not fit side by side.
    static func placement(_ choice: Choice, detailWidth: Double, windowHeight: Double, canSpan: Bool) -> Placement {
        let bottom: Placement = canSpan ? .bottom : .below
        switch choice {
        case .right: return detailWidth >= rightFitsFrom ? .right : .below
        case .below: return .below
        case .bottom: return bottom
        case .automatic:
            if detailWidth >= autoRightFrom { return .right }
            return windowHeight >= bottomFromHeight ? bottom : .below
        }
    }

    /// The pane's width or height, kept inside its range and leaving room for the page it sits next to. A stored height of zero
    /// is half the available height.
    static func paneLength(_ stored: Double, placement: Placement, available: Double) -> Double {
        switch placement {
        case .right: return min(max(stored, rightRange.lowerBound), min(rightRange.upperBound, available - minimumPageWidth - handleLength))
        case .below, .bottom:
            let wanted = stored > 0 ? stored : available / 2
            return min(max(wanted, belowRange.lowerBound), min(belowRange.upperBound, available - minimumPageHeight - handleLength))
        }
    }
}
