#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-resume <folder>` saves PNGs of the resume card with made-up data, alone and in the notch
/// bar, and of its settings. Nothing is stored and nothing is fetched.
enum ResumePreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-resume", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bar = NotchBar(screen: NSScreen.main ?? NSScreen.screens[0])
        let resume = ResumeModel.shared
        Task { @MainActor in
            func shot(_ name: String, _ view: some View, appearance: NSAppearance.Name = .darkAqua) async {
                await NotchPreview.render(view, appearance: appearance, to: output.appendingPathComponent("\(name).png"))
            }
            func notch(_ name: String, list: NotchPanelID?, peeking: Bool = false) async {
                await shot(name, bar.sample(list: list, hasNotch: true, peeking: peeking).frame(width: 640).padding(.bottom, 8)
                    .background(Color.gray.opacity(0.35)))
            }
            let card = sample, quiet = quietSample
            await shot("card", ResumeCardView(card: card, now: now).frame(width: 588).padding(.vertical, 14).background(Color.black)
                .environment(\.colorScheme, .dark))
            await shot("card-quiet-ticket", ResumeCardView(card: quiet, now: now).frame(width: 588).padding(.vertical, 14).background(Color.black)
                .environment(\.colorScheme, .dark))
            resume.showSample(card, unseen: true)
            await notch("bar-dot", list: nil)
            resume.showSample(card, unseen: false)
            await notch("bar-peek", list: nil, peeking: true)
            await notch("bar-open-with-list", list: .todo)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                await shot("settings-\(appearance == .aqua ? "light" : "dark")", ResumeSettingsSection().padding(24).frame(width: 520)
                    .background(Color(nsColor: .windowBackgroundColor)), appearance: appearance)
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static let now = Date()

    private static var sample: ResumeCard {
        let session = ClaudeSession(id: "s1", folder: "/Users/me/git/finq.api", title: "Rounding of voucher rows")
        let visit = ResumeVisit(start: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-23.5 * 3600), active: 1.9 * 3600,
                                sessions: [session])
        return ResumeCard(
            key: ResumeContextKey(repo: "finq.api", branch: "NI/QDLY-8734", ticket: "QDLY-8734"), entered: now, visit: visit,
            prompts: [ResumePrompt(session: session.title, text: "make test_round_half_up pass without touching the bookkeeping export", date: nil),
                      ResumePrompt(session: session.title, text: "why does the voucher total differ by one öre on credit notes?", date: nil)],
            pr: ResumePR(url: "https://github.com/quiddly-com/finq.api/pull/2591", repo: "quiddly-com/finq.api", number: 2591,
                         title: "QDLY-8734: Round voucher rows half up", state: .open, checks: .failed, review: .changesRequested, unresolved: 2,
                         newCommits: ["Address review", "Fix flake"], newComments: [
                            ResumeComment(author: "jessica", text: "Can we keep the old rounding for imported vouchers?", date: nil),
                            ResumeComment(author: "bo-lind", text: "Tests fail on Python 3.12 only", date: nil)],
                         finishedChecks: ["tests failed", "lint passed"]),
            ticket: ResumeTicket(key: "QDLY-8734", summary: "Voucher rows are rounded down on credit notes", status: "Review",
                                 assignee: "Niklas Inde", changes: ["Status: In Progress \u{2192} Review (Niklas Inde)"],
                                 newComments: [ResumeComment(author: "Anna Berg", text: "Customer confirmed the fix on testadmin", date: nil)]),
            meetings: [ResumeMention(meeting: 412, title: "Daily standup", date: now.addingTimeInterval(-3 * 3600),
                                     line: "03:12 Anna: QDLY 8734 should go out with Thursday's release")],
            agent: ResumeAgent(key: "https://github.com/quiddly-com/finq.api/pull/2591", title: "finq.api #2591",
                               prURL: "https://github.com/quiddly-com/finq.api/pull/2591", status: "idle",
                               lastResult: "Fixed the rounding and added two tests; the review thread about imported vouchers is still open."))
    }

    private static var quietSample: ResumeCard {
        ResumeCard(key: ResumeContextKey(ticket: "ISD-1203"), entered: now,
                   visit: ResumeVisit(start: now.addingTimeInterval(-5 * 3600), end: now.addingTimeInterval(-4.6 * 3600), active: 1500,
                                      prompts: ["check why Intrum UAT login fails for the new tenant"]),
                   ticket: ResumeTicket(key: "ISD-1203", summary: "Intrum UAT login fails", status: "Waiting for support", assignee: "Niklas Inde"))
    }
}
#endif
