import AVFoundation
import AppKit
import CoreGraphics

enum PermissionError: LocalizedError {
    case microphone
    case screenRecording

    var errorDescription: String? {
        switch self {
        case .microphone: return "Microphone access denied."
        case .screenRecording: return "Screen Recording access denied (needed for system audio)."
        }
    }
}

enum Permissions {
    static func ensureAll() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw PermissionError.microphone }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw PermissionError.screenRecording
        }
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openPrivacySettings(pane: String = "Privacy") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() { openPrivacySettings(pane: "Privacy_Microphone") }
    static func openScreenRecordingSettings() { openPrivacySettings(pane: "Privacy_ScreenCapture") }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
