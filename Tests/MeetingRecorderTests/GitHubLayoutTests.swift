import Foundation

let githubLayoutTests: [(name: String, run: () throws -> Void)] = [
    ("the list keeps its range and leaves the page its minimum", {
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1500) == 420, "the default is kept")
        check(GitHubLayout.listWidth(100, in: 1500) == 320, "minimum")
        check(GitHubLayout.listWidth(900, in: 2560) == 560, "maximum")
        check(GitHubLayout.listWidth(560, in: 900) == 480, "the page keeps its minimum width")
    }),

    ("wide windows put the terminal beside the page, from the same breakpoint as before", {
        check(EmbeddedTerminal.placement(width: EmbeddedTerminal.rightFromWidth) == .right, "1500 is right")
        check(EmbeddedTerminal.placement(width: EmbeddedTerminal.rightFromWidth - 1) == .below, "1499 is below")
        check(GitHubLayout.compactBelow < EmbeddedTerminal.rightFromWidth, "the list and page turn before the terminal moves")
    }),

    ("the three columns at the widths that matter, with the page never wider than its column", {
        // list, then the splitter, then the terminal beside the page, then the page; the page column is capped at pageWidth.
        func columns(_ total: Double) -> (list: Double, terminal: Double, page: Double) {
            let list = GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: total)
            let rest = total - list - 1
            let terminal = EmbeddedTerminal.paneLength(EmbeddedTerminal.defaultRight, placement: .right, available: rest)
            return (list, terminal, rest - terminal - 1)
        }
        let at1500 = columns(1500), at1728 = columns(1728), at2048 = columns(2048), at2560 = columns(2560)
        check(at1500.list == 420 && at1500.terminal == 560 && at1500.page == 518, "1500: list 420, terminal 560, page 518")
        check(at1728.page == 746, "1728: the page gets the rest")
        check(at2048.terminal == 560 && min(at2048.page, GitHubLayout.pageWidth) == 1000, "2048: the page column is capped")
        check(at2560.terminal == 560 && min(at2560.page, GitHubLayout.pageWidth) == 1000, "2560: the page column is capped")
        check(at2560.list + at2560.terminal + at2560.page + 2 == 2560, "the columns add up to the window")
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 2139) == 720, "the terminal stops at its widest")
    }),

    ("the reading width keeps prose near 100 characters and inside the page column", {
        check((760...860).contains(GitHubLayout.readingWidth), "reading width between 760 and 860")
        check(GitHubLayout.readingWidth <= GitHubLayout.pageWidth, "prose never wider than the page column")
    }),

    ("the list rows show their metadata only from 2200 points", {
        check(!GitHubLayout.showsRowMetadata(width: 2199), "2199 has no metadata line")
        check(GitHubLayout.showsRowMetadata(width: 2200), "2200 has it")
        check(GitHubLayout.showsRowMetadata(width: 2560), "2560 has it")
    }),
]
