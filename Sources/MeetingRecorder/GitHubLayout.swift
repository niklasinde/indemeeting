import Foundation

/// The widths of the GitHub view: the list, the page's reading column and when the rows show their metadata. Pure, so the
/// breakpoints are tested without a window; the terminal's side is in EmbeddedTerminal.
enum GitHubLayout {
    /// The list never gets narrower than this: its tabs, filters and search need the room, and below it the list's content
    /// would overflow the pane on both sides.
    static let listWidths = 360.0...560.0
    static let defaultListWidth = 420.0
    static let splitterWidth = EmbeddedTerminal.handleLength
    /// The narrowest the page column gets beside the list.
    static let pageMinimum = EmbeddedTerminal.minimumPageWidth
    /// Below this the list and the page take turns instead of sitting side by side.
    static let compactBelow = listWidths.lowerBound + splitterWidth + pageMinimum
    /// The widest the page column gets. The file, check and commit lists use all of it.
    static let pageWidth = 1000.0
    /// The widest prose (header, description, reviews, comments) gets, which keeps lines near 100 characters.
    static let readingWidth = 760.0
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
        let upper = min(listWidths.upperBound, total - splitterWidth - pageMinimum)
        return min(max(stored, listWidths.lowerBound), upper)
    }

    static func showsRowMetadata(width: Double) -> Bool { width >= metadataFrom }
}
