import Foundation

let githubLayoutTests: [(name: String, run: () throws -> Void)] = [
    ("the list keeps its range and leaves the page its minimum", {
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1500) == 420, "the default is kept")
        check(GitHubLayout.listWidth(100, in: 1500) == 240, "minimum")
        check(GitHubLayout.listWidth(900, in: 2560) == 560, "maximum")
        check(GitHubLayout.listWidth(560, in: 900) == 280, "a narrow window caps the list at 280 and the page keeps its minimum")
    }),

    ("a stored width is clamped for the window, and an out-of-range value is repaired to the default on load", {
        check(GitHubLayout.listWidth(130, in: 1500) == 240, "130 clamps to the list minimum")
        check(GitHubLayout.listWidth(1200, in: 1500) == 560, "1200 clamps to the list maximum")
        check(GitHubLayout.listWidth(1200, in: 900) == 280, "1200 in a 900 window is capped narrow and leaves the page its minimum")
        check(GitHubLayout.listWidth(500, in: GitHubLayout.compactBelow - 1) == 0, "too narrow for two panes gives no list")
        check(GitHubLayout.repairedWidth(130) == GitHubLayout.defaultListWidth, "130 is repaired to the default")
        check(GitHubLayout.repairedWidth(1200) == GitHubLayout.defaultListWidth, "1200 is repaired to the default")
        check(GitHubLayout.repairedWidth(480) == 480, "a value in range is kept")
    }),

    ("with and without the terminal, at every width the list is 0 or at least 360 and the columns fit", {
        for total in [780.0, 900, 1100, 1280, 1440, 1500, 1728, 2048, 2560] {
            for stored in [130.0, 420, 560, 1200] {
                let list = GitHubLayout.listWidth(stored, in: total)
                check(list == 0 || (240...560).contains(list), "list \(list) at \(total) is 0 or in range")
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
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 720) == 0, "720 is still one pane at a time")
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 721) == 240, "721 is the first side by side width")
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
        check(EmbeddedTerminal.paneLength(2000, placement: .right, available: 1000) == 519, "the terminal leaves the page its minimum and the handle")
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

    ("the list is narrow below 1200 points and its rows are one line at the narrow width", {
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1000) == 280, "1000 caps the list at 280")
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1100) == 280, "1100 caps the list at 280")
        check(GitHubLayout.listWidth(GitHubLayout.defaultListWidth, in: 1280) == 420, "1280 keeps the wide default")
        check(GitHubLayout.singleLineRows(listWidth: 280), "a 280 list is one line")
        check(!GitHubLayout.singleLineRows(listWidth: 420), "a 420 list is not")
    }),

    ("prose is capped only in a wide page column", {
        check(GitHubLayout.proseWidth(column: 859) == nil, "a 1280 window's column is used in full")
        check(GitHubLayout.proseWidth(column: 1079) == GitHubLayout.readingWidth, "a wide column is capped at the reading width")
    }),

    ("the toolbar keeps the actions in one row when they fit and moves the rest into More in priority order", {
        let all = GitHubLayout.PageAction.allCases
        let wide = GitHubLayout.toolbar(width: 2000, present: all)
        check(wide.visible == all && wide.overflow.isEmpty, "a wide page shows every action, no More menu")
        check(GitHubLayout.toolbar(width: 2000, present: all.filter { $0 != .terminal }).visible.count == 7, "no terminal means no terminal button")
        let narrow = GitHubLayout.toolbar(width: 727, present: all)
        check(narrow.visible.contains(.openInBrowser) && narrow.visible.contains(.copy) && narrow.visible.contains(.ask)
              && narrow.visible.contains(.review), "the first four stay at 727")
        check(narrow.overflow.contains(.merge) && narrow.overflow.contains(.close), "Merge and Close move into More when narrow")
        check(narrow.visible + narrow.overflow == all, "every action is either visible or in More, in order")
        let tiny = GitHubLayout.toolbar(width: 240, present: all)
        check(tiny.visible == [.openInBrowser], "at 240 only the first action stays")
        check(tiny.visible + tiny.overflow == all, "nothing is lost at 240")
    }),
]
