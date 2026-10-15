import AVFoundation
import AppKit
import UserNotifications

enum PermissionError: LocalizedError {
    case microphone

    var errorDescription: String? { "Microphone access denied." }
}

enum Permissions {
    static func ensureMicrophone() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw PermissionError.microphone }
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var microphoneReady: Bool { microphoneStatus == .authorized }
    static var allGranted: Bool { microphoneReady && systemAudio == .granted }

    /// "System Audio Recording Only" (kTCCServiceAudioCapture) has no public status API; the TCC calls are looked up at
    /// runtime and report `.unknown` when missing. The first process tap start also triggers the prompt.
    static var systemAudio: SystemAudioAccess {
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight(TCC.audioCapture, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func requestSystemAudio() async -> Bool {
        guard let request = TCC.request else { return false }
        return await withCheckedContinuation { continuation in
            request(TCC.audioCapture, nil) { continuation.resume(returning: $0) }
        }
    }

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
    static func openSystemAudioSettings() { openPrivacySettings(pane: "Privacy_ScreenCapture") }
}

private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    static let audioCapture = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    static let preflight = symbol("TCCAccessPreflight", as: Preflight.self)
    static let request = symbol("TCCAccessRequest", as: Request.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: type) }
    }
}
