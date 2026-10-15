import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: delegate.recorder)
        } label: {
            MenuLabel(recorder: delegate.recorder)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        OnboardingWindow.shared.recorder = recorder
        OnboardingWindow.shared.showIfFirstLaunch()
    }
}

struct MenuLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Image(nsImage: MenuIcon.image(recording: recorder.isRecording))
    }
}

struct MenuContent: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        if recorder.isRecording {
            Text("Recording  \(recorder.elapsedText)")
            Button("Stop Recording") { Task { await recorder.stop() } }
        } else {
            Button("Start Recording") { Task { await recorder.start() } }
        }
        if let message = recorder.errorMessage {
            Divider()
            Text(message)
            if recorder.permissionDenied {
                Button("Open Privacy Settings") { Permissions.openPrivacySettings() }
            }
        }
        Divider()
        Button("Open Recordings Folder") { recorder.openFolder() }
        Button("Setup & Help…") { OnboardingWindow.shared.show() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MenuIcon {
    static func image(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "waveform.circle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Recorder") ?? NSImage()
        guard recording else {
            base.isTemplate = true
            return base
        }
        let image = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) ?? base
        image.isTemplate = false
        return image
    }
}
