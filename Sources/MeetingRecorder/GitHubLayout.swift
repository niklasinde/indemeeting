import Foundation

/// The widths of the GitHub view: the list, the page's reading column and when the rows show their metadata. Pure, so the
/// breakpoints are tested without a window; the terminal's side is in EmbeddedTerminal.
enum GitHubLayout {
    static let listWidths = 320.0...560.0
    static let defaultListWidth = 420.0
    /// Below this the list and the page take turns instead of sitting side by side.
    static let compactBelow = 780.0
    /// The widest the page column gets. The file, check and commit lists use all of it.
    static let pageWidth = 1000.0
    /// The widest prose (header, description, reviews, comments) gets, which keeps lines near 100 characters.
    static let readingWidth = 760.0
    /// From this width the list rows add a line with the author, the update time and the changes.
    static let metadataFrom = 2200.0

    /// The list's width, kept in its range and leaving the page its minimum.
    static func listWidth(_ stored: Double, in total: Double) -> Double {
        min(max(stored, listWidths.lowerBound), min(listWidths.upperBound, total - EmbeddedTerminal.minimumPageWidth))
    }

    static func showsRowMetadata(width: Double) -> Bool { width >= metadataFrom }
}
