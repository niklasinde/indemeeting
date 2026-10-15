#if DEBUG
import AVFoundation
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-previews <folder>` writes a sample library to `<folder>/library` and
/// saves PNGs of the main window in light and dark appearance, so the layout can be checked without a screen.
enum PreviewRenderer {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-previews"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let folder = output.appendingPathComponent("library", isDirectory: true)
        do {
            try SampleLibrary.write(to: folder, now: Date())
        } catch {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let database = output.appendingPathComponent("library.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        let store: MeetingStore
        do {
            store = try MeetingStore.open(at: database)
        } catch {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let (library, window) = makeWindow(store: store, folder: folder)
        if let standup = library.recordings.first {
            try? store.saveTranscript(standup.fileName, segments: SampleLibrary.labelledTranscript, language: .swedish,
                                      engine: "DictationTranscriber")
        }

        let shots: [(name: String, meeting: Int, tab: DetailTab)] = [
            ("summary", 0, .summary), ("transcript", 0, .transcript), ("notes", 0, .notes),
            ("legacy-summary", 1, .summary), ("no-summary", 2, .summary),
        ]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for shot in shots {
                    library.selection = library.recordings[shot.meeting].id
                    library.tab = shot.tab
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let mode = appearance == .aqua ? "light" : "dark"
                    save(window, to: output.appendingPathComponent("\(shot.name)-\(mode).png"))
                }
            }
            window.orderOut(nil)
            let unavailable = MeetingStore.openDefault(at: URL(fileURLWithPath: "/dev/null/meetings.sqlite"))
            let (brokenLibrary, brokenWindow) = makeWindow(store: unavailable, folder: folder)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            brokenLibrary.selection = brokenLibrary.recordings.first?.id
            brokenLibrary.tab = .notes
            try? await Task.sleep(nanoseconds: 700_000_000)
            save(brokenWindow, to: output.appendingPathComponent("database-unavailable-light.png"))
            exit(0)
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func makeWindow(store: MeetingStore, folder: URL) -> (RecordingLibrary, NSWindow) {
        let library = RecordingLibrary(store: store, folder: folder)
        library.start()
        let window = MainWindow.makeWindow(MainView(recorder: Recorder(), processor: MeetingProcessor(notifier: nil, store: store),
                                                    library: library, playback: AudioPlayback()))
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        return (library, window)
    }

    @MainActor
    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}

private enum SampleLibrary {
    static func write(to folder: URL, now: Date) throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let calendar = Calendar.current
        func day(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0,
                          of: calendar.date(byAdding: .day, value: offset, to: now)!)!
        }

        let standup = try meeting(in: folder, at: day(0, 9, 31), minutes: 18)
        try write(ProcessingLogic.transcriptMarkdown(audioName: standup.lastPathComponent, language: .swedish,
                                                     engine: "DictationTranscriber", segments: transcript),
                  to: ProcessingLogic.transcriptURL(for: standup))
        try write(ProcessingLogic.summaryMarkdown(standupSummary, audioName: standup.lastPathComponent, language: .swedish),
                  to: ProcessingLogic.summaryURL(for: standup))
        let checked = "Sara: Skriv release notes för 4.12"
        try MeetingMeta(checked: [checked: true]).encoded().write(to: ProcessingLogic.metaURL(for: standup))
        try write("Fråga Johan om fixen också gäller kreditfakturor.\n\nKundteamet vill ha releasedatum senast fredag.\n",
                  to: ProcessingLogic.notesURL(for: standup))

        let planning = try meeting(in: folder, at: day(-1, 14, 2), minutes: 31)
        try write(legacySummary(planning.lastPathComponent), to: ProcessingLogic.summaryURL(for: planning))

        let review = try meeting(in: folder, at: day(-2, 10, 15), minutes: 12)
        try write(ProcessingLogic.unavailableMarkdown(.appleIntelligenceOff, audioName: review.lastPathComponent, language: .swedish),
                  to: ProcessingLogic.summaryURL(for: review))
        try write(ProcessingLogic.transcriptMarkdown(audioName: review.lastPathComponent, language: .swedish,
                                                     engine: "DictationTranscriber", segments: Array(transcript.prefix(4))),
                  to: ProcessingLogic.transcriptURL(for: review))

        _ = try meeting(in: folder, at: day(-9, 13, 0), minutes: 45)
        _ = try meeting(in: folder, at: day(-23, 8, 45), minutes: 7)
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A silent AAC file of the given length, named like a real recording.
    private static func meeting(in folder: URL, at date: Date, minutes: Double) throws -> URL {
        let url = folder.appendingPathComponent(RecordingLogic.fileName(for: date))
        let rate = 8000.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                               AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * 60))!
        buffer.frameLength = buffer.frameCapacity
        for _ in 0..<Int(minutes) { try file.write(from: buffer) }
        return url
    }

    private static let standupSummary = MeetingSummary(
        title: "Daglig standup \u{2013} buggfynd, validering och release",
        actionItems: [
            .init(task: "Validera de 6 öppna ticketsen innan kl. 16:00", owner: "Katja"),
            .init(task: "Rätta avrundningen av belopp på artikelrader", owner: "Johan"),
            .init(task: "Skriv release notes för 4.12", owner: "Sara"),
            .init(task: "Sätt upp testdata för fakturaflödet", owner: "Ahmed"),
            .init(task: "Boka genomgång av releaseplanen med kundteamet", owner: "Niklas"),
        ],
        topics: [
            .init(title: "Bugg \u{2013} artikelrader och belopp", points: [
                "Belopp på artikelrader avrundas fel när rabatt kombineras med moms.",
                "Felet syns bara på fakturor med fler än 20 rader.",
                "Johan har en fix som går till granskning i dag.",
            ]),
            .init(title: "Validering av öppna tickets", points: [
                "Sex tickets väntar på validering i testmiljön.",
                "Två av dem är blockerade tills testdata finns på plats.",
            ]),
            .init(title: "Release 4.12", points: [
                "Releasen planeras till tisdag om valideringen blir klar.",
                "Release notes och kundinformation ska vara klara på måndag.",
            ]),
        ])

    private static let transcript: [TranscriptSegment] = [
        (4, "God morgon allihop, ska vi köra igång?"),
        (9, "Jag börjar med buggen på artikelraderna som kom in i går."),
        (17, "Beloppen avrundas fel när man har både rabatt och moms på samma rad."),
        (41, "Det syns bara på fakturor med fler än tjugo rader, så det är därför vi inte hittade det tidigare."),
        (55, "Jag har en fix klar och lägger upp den för granskning efter mötet."),
        (78, "Bra. Katja, hur ser det ut med valideringen?"),
        (84, "Vi har sex öppna tickets kvar och jag tänkte bli klar med dem innan fyra i dag."),
        (97, "Två av dem kräver testdata som vi inte har än."),
        (112, "Det fixar jag, jag sätter upp testdata för fakturaflödet direkt efter lunch."),
        (139, "Då går vi vidare till releasen."),
        (146, "Om valideringen blir klar kan vi släppa fyra punkt tolv på tisdag."),
        (163, "Jag skriver release notes, de ska vara klara på måndag."),
        (181, "Och jag bokar en genomgång med kundteamet så att de vet vad som kommer."),
        (196, "Toppen, då kör vi. Tack allihop!"),
    ].map { TranscriptSegment(start: $0.0, text: $0.1) }

    static let labelledTranscript = transcript.enumerated().map { index, segment in
        TranscriptSegment(start: segment.start, text: segment.text,
                          speaker: [0, 5, 6, 7, 9, 10, 13].contains(index) ? .you : .others)
    }

    private static func legacySummary(_ audioName: String) -> String {
        """
        # Planering Q4 \u{2013} budget och rekrytering

        _\(audioName) \u{00B7} Svenska \u{00B7} on-device Apple Intelligence_

        ## Sammanfattning

        Teamet gick igenom budgeten för Q4 och behovet av två nya utvecklare.

        ## Viktiga punkter

        - Kostnaderna ligger 8 % över plan.
        - Rekryteringen startar i november.

        ## Beslut

        - Budgeten för konsulter halveras.

        ## Åtgärder

        - [ ] Ta fram en ny kostnadsprognos \u{2014} **Maria**
        - [ ] Skriv annonsen för utvecklartjänsterna

        """
    }
}
#endif
