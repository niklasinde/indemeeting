import AVFoundation
import AppKit
import CoreGraphics
import UserNotifications

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
    static func ensureMicrophone() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw PermissionError.microphone }
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var notificationStatus: UNAuthorizationStatus {
        get async { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func openPrivacySettings(pane: String = "Privacy") {
        openSettings("com.apple.preference.security?\(pane)")
    }

    private static func openSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openNotificationSettings() { openSettings("com.apple.preference.notifications") }
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
