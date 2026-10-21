import Foundation

/// The widths of the GitHub view: the list, the page column, the page toolbar and when the rows show their metadata. Pure, so
/// the breakpoints are tested without a window; the terminal's side and height are in EmbeddedTerminal.
enum GitHubLayout {
    /// Below `narrowBelow` the list is narrow, so the page column gets the room; wider windows keep the full range.
    static let listWidths = 240.0...560.0
    static let narrowListWidths = 240.0...280.0
    static let narrowBelow = 1200.0
    static let defaultListWidth = 420.0
    static let splitterWidth = EmbeddedTerminal.handleLength
    /// The narrowest the page column gets beside the list.
    static let pageMinimum = 480.0
    /// Below this the list and the page take turns instead of sitting side by side.
    static let compactBelow = narrowListWidths.lowerBound + splitterWidth + pageMinimum
    /// Below this list width each row is one line: the title and a line of its chips.
    static let singleLineRowsBelow = 300.0
    /// From this window height the Claude session is a bottom half across the whole window, and the list and page the top half.
    static let stackedFromHeight = 900.0
    /// The widest the page column gets. The file, check and commit lists use all of it.
    static let pageWidth = 1000.0
    /// Prose (header, description, reviews, comments) stops at this width once the column is wide, which keeps lines near 100
    /// characters; a narrower column is used in full.
    static let readingWidth = 760.0
    static let proseCapFrom = 1000.0
    /// From this width the list rows add a line with the author, the update time and the changes.
    static let metadataFrom = 2200.0

    /// A stored width outside the list's range (an old value, or a hand edit) goes back to the default.
    static func repairedWidth(_ stored: Double) -> Double {
        listWidths.contains(stored) ? stored : defaultListWidth
    }

    /// The list's width in a window of `total` points: kept in its range and leaving the page its minimum. Zero when the
    /// window is too narrow for the two side by side, so the view shows one pane at a time.
    static func listWidth(_ stored: Double, in total: Double) -> Double {
        guard total >= compactBelow else { return 0 }
        let range = total < narrowBelow ? narrowListWidths : listWidths
        let upper = min(range.upperBound, total - splitterWidth - pageMinimum)
        return min(max(stored, range.lowerBound), upper)
    }

    static func showsRowMetadata(width: Double) -> Bool { width >= metadataFrom }

    static func singleLineRows(listWidth: Double) -> Bool { listWidth < singleLineRowsBelow }

    static func stacksTerminal(width: Double, height: Double) -> Bool { width >= compactBelow && height >= stackedFromHeight }

    /// The cap on prose in a page column of `column` points: nil (no cap) while the column is narrow.
    static func proseWidth(column: Double) -> Double? { column >= proseCapFrom ? readingWidth : nil }

    // MARK: Page toolbar

    /// The page's actions in the order they give way: the first ones stay in the toolbar longest.
    enum PageAction: CaseIterable {
        case openInBrowser, copy, ask, review, openInClaude, terminal, merge, close
    }

    static let toolbarSpacing = 8.0
    static let moreWidth = 70.0

    /// Estimated width of each button with its label, so the overflow is decided without a layout pass.
    static func buttonWidth(_ action: PageAction) -> Double {
        switch action {
        case .openInBrowser: return 128
        case .copy: return 76
        case .ask: return 72
        case .review: return 84
        case .openInClaude: return 124
        case .terminal: return 88
        case .merge: return 76
        case .close: return 76
        }
    }

    /// The actions that stay in the toolbar of a page `width` points wide, and those that move into its More menu. When
    /// everything fits there is no More menu; otherwise the first actions in priority order stay.
    static func toolbar(width: Double, present: [PageAction]) -> (visible: [PageAction], overflow: [PageAction]) {
        func total(_ actions: [PageAction]) -> Double {
            actions.isEmpty ? 0 : actions.reduce(0) { $0 + buttonWidth($1) } + toolbarSpacing * Double(actions.count - 1)
        }
        if total(present) <= width { return (present, []) }
        var visible: [PageAction] = []
        for action in present {
            guard total(visible + [action]) + toolbarSpacing + moreWidth <= width else { break }
            visible.append(action)
        }
        return (visible, Array(present.dropFirst(visible.count)))
    }
}
