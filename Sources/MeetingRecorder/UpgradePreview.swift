#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `MeetingRecorder --render-upgrade <folder>` saves the main window with the upgrade banner, in light and dark.
enum UpgradePreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-upgrade"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("upgrade.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database) else { exit(1) }
        let library = RecordingLibrary(store: store, folder: output.appendingPathComponent("empty", isDirectory: true))
        library.start()
        let window = MainWindow.makeWindow(MainView(recorder: Recorder(), processor: MeetingProcessor(notifier: nil, store: store), library: library,
                                                    activity: ActivityModel(store: store, tracker: ActivityTracker(store: store)),
                                                    playback: AudioPlayback()))
        window.setContentSize(NSSize(width: 980, height: 520))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        AppUpgrade.shared.showSample(ready: true)
        Task { @MainActor in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 900_000_000)
                PreviewRenderer.save(window, to: output.appendingPathComponent(appearance == .aqua ? "upgrade-light.png" : "upgrade-dark.png"))
            }
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }
}
#endif
