#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-brief <folder>` saves PNGs of a meeting brief card with made-up data, in the notch bar and
/// in light and dark, and of the setting, and writes the brief's text to `<folder>/brief.txt`.
@MainActor
enum MeetingBriefPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-brief", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Task { @MainActor in
            let now = Date()
            let full = sample(now), quiet = MeetingBrief(event: event(now, minutes: 5, title: "1:1 Bo", people: [CalendarAttendee(name: "Bo Lind", email: nil)]))
            try? MeetingBriefLogic.text(full).write(to: output.appendingPathComponent("brief.txt"), atomically: true, encoding: .utf8)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                await NotchPreview.render(card(full, now: now), appearance: appearance, to: output.appendingPathComponent("card-\(suffix).png"))
                await NotchPreview.render(card(quiet, now: now), appearance: appearance, to: output.appendingPathComponent("card-quiet-\(suffix).png"))
                await NotchPreview.render(SettingsPreviewPage { MeetingBriefSettingsSection() }, appearance: appearance,
                                          to: output.appendingPathComponent("settings-\(suffix).png"))
            }
            MeetingBriefModel.shared.showSample([full, quiet], unseen: 2)
            let bar = NotchBar(screen: NSScreen.main ?? NSScreen.screens[0])
            await NotchPreview.render(bar.sample(list: nil, hasNotch: true, peeking: true).frame(width: 640).padding(.bottom, 8)
                .background(Color.gray.opacity(0.35)), appearance: .darkAqua, to: output.appendingPathComponent("notch.png"))
            await NotchPreview.render(bar.sample(list: nil, hasNotch: true).frame(width: 640, height: 80, alignment: .top)
                .background(Color.gray.opacity(0.35)), appearance: .darkAqua, to: output.appendingPathComponent("notch-badge.png"))
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static func card(_ brief: MeetingBrief, now: Date) -> some View {
        MeetingBriefCardView(brief: brief, now: now).frame(width: 588).padding(14).background(Color.black).environment(\.colorScheme, .dark)
    }

    private static func event(_ now: Date, minutes: Double, title: String, people: [CalendarAttendee]) -> CalendarEventInfo {
        CalendarEventInfo(id: title, seriesID: "gaia-weekly", title: title, start: now.addingTimeInterval(minutes * 60 + 20),
                          end: now.addingTimeInterval(minutes * 60 + 1820), attendees: people)
    }

    private static func sample(_ now: Date) -> MeetingBrief {
        var last = PastMeeting(id: 1, title: "Gaia-exporten blir CSV", date: now.addingTimeInterval(-7 * 86400))
        last.decisions = ["Exporten går som CSV med semikolon.", "Excel-formatet väntar till Q1."]
        last.openItems = ["Anna: Testa exporten mot Gaias testmiljö"]
        var older = PastMeeting(id: 2, title: "Release av sökningen", date: now.addingTimeInterval(-14 * 86400))
        older.openItems = ["Skriva release notes"]
        return MeetingBrief(event: event(now, minutes: 10, title: "Gaia \u{00B7} weekly export sync",
                                         people: [CalendarAttendee(name: "Anna Berg", email: nil), CalendarAttendee(name: "Bo Lind", email: nil),
                                                  CalendarAttendee(name: nil, email: "elin@gaia.example")]),
                            earlier: [last, older],
                            tickets: [.init(key: "QDLY-9031", summary: "Export invoices to Gaia as CSV", status: "In Review", assignee: "Niklas Inde")],
                            pullRequests: [.init(repo: "quiddly-com/finq.api", number: 2688, title: "QDLY-9031: Export invoices as CSV", state: "Open",
                                                 checks: "Checks passed", review: "Approved")],
                            agenda: "1. CSV export status (QDLY-9031)\n2. Search fields",
                            focus: "Confirm CSV with semicolons and who tests against Gaia's environment.")
    }
}

private struct SettingsPreviewPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View { content.padding(24).frame(width: 520).background(Color(nsColor: .windowBackgroundColor)) }
}
#endif
