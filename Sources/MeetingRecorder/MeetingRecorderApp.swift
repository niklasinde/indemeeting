import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: recorder)
        } label: {
            Image(nsImage: MenuIcon.image(recording: recorder.isRecording))
        }
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
