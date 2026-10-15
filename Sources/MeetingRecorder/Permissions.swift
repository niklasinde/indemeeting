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

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
