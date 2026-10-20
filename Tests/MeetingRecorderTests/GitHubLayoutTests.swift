import Foundation

let githubLayoutTests: [(name: String, run: () throws -> Void)] = [
    ("the list keeps its range and leaves the page its minimum", {
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1500) == 420, "the default is kept")
        check(GitHubLayout.listWidth(100, in: 1500) == 360, "minimum")
        check(GitHubLayout.listWidth(900, in: 2560) == 560, "maximum")
        check(GitHubLayout.listWidth(560, in: 900) == 479, "the page keeps its minimum width beside the splitter")
    }),

    ("a stored width is clamped for the window, and an out-of-range value is repaired to the default on load", {
        check(GitHubLayout.listWidth(130, in: 1500) == 360, "130 clamps to the list minimum")
        check(GitHubLayout.listWidth(1200, in: 1500) == 560, "1200 clamps to the list maximum")
        check(GitHubLayout.listWidth(1200, in: 900) == 479, "1200 in a 900 window leaves the page its minimum")
        check(GitHubLayout.listWidth(500, in: GitHubLayout.compactBelow - 1) == 0, "too narrow for two panes gives no list")
        check(GitHubLayout.repairedWidth(130) == GitHubLayout.defaultListWidth, "130 is repaired to the default")
        check(GitHubLayout.repairedWidth(1200) == GitHubLayout.defaultListWidth, "1200 is repaired to the default")
        check(GitHubLayout.repairedWidth(480) == 480, "a value in range is kept")
    }),

    ("with and without the terminal, at every width the list is 0 or at least 360 and the columns fit", {
        for total in [780.0, 900, 1100, 1280, 1440, 1500, 1728, 2048, 2560] {
            for stored in [130.0, 420, 560, 1200] {
                let list = GitHubLayout.listWidth(stored, in: total)
                check(list == 0 || list >= 360, "list \(list) at \(total) is 0 or at least 360")
                guard list > 0 else { continue }
                let rest = total - list - GitHubLayout.splitterWidth
                check(rest >= GitHubLayout.pageMinimum, "page keeps its minimum at \(total)")
                check(list + GitHubLayout.splitterWidth + rest <= total, "columns fit at \(total)")
                if EmbeddedTerminal.placement(width: total) == .right {
                    let terminal = EmbeddedTerminal.paneLength(EmbeddedTerminal.defaultRight, placement: .right, available: rest)
                    let page = rest - terminal - 1
                    check(page >= GitHubLayout.pageMinimum, "with the terminal open the page keeps its minimum at \(total)")
                    check(list + 1 + page + 1 + terminal == total, "the three columns add up at \(total)")
                }
            }
        }
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 780) == 0, "780 is still one pane at a time")
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 781) == 360, "781 is the first side by side width")
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
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 2140) == 720, "the terminal stops at its widest")
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 1000) == 579, "the terminal leaves the page its minimum and the handle")
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
