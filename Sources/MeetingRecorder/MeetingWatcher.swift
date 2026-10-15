import AppKit
import Combine
import CoreAudio
import UserNotifications

@MainActor
final class MeetingWatcher {
    static let enabledKey = "notifyOnMeetingStart"

    private let recorder: Recorder
    private let notifier: MeetingNotifier
    private var detector = MeetingDetector()
    private var monitor: MicrophoneActivityMonitor?
    private var recheck: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(recorder: Recorder) {
        self.recorder = recorder
        notifier = MeetingNotifier { await recorder.start() }
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func start() {
        Task { _ = await Permissions.requestNotifications() }
        monitor = MicrophoneActivityMonitor { [weak self] in self?.evaluate() }
        subscription = recorder.$isRecording.sink { [weak self] in self?.evaluate(recording: $0) }
    }

    private func evaluate(recording: Bool? = nil) {
        let busy = monitor?.isInUse ?? false
        if !busy { notifier.withdraw() }
        recheck?.cancel()
        switch detector.update(micBusy: busy, recording: recording ?? recorder.isRecording, now: Date()) {
        case .idle:
            break
        case .wait(let delay):
            recheck = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled { self?.evaluate() }
            }
        case .notify:
            if enabled { notifier.post(appName: Self.meetingAppName) }
        }
    }

    private static var meetingAppName: String? {
        let workspace = NSWorkspace.shared
        return MeetingApps.name(frontmost: workspace.frontmostApplication?.bundleIdentifier,
                                running: workspace.runningApplications.compactMap(\.bundleIdentifier))
    }
}

final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "meeting-started"
    private static let recordAction = "record"
    private static let identifier = "meeting-started"

    private let onRecord: @MainActor @Sendable () async -> Void
    private let center = UNUserNotificationCenter.current()

    init(onRecord: @escaping @MainActor @Sendable () async -> Void) {
        self.onRecord = onRecord
        super.init()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [record],
                                                                 intentIdentifiers: [], options: [])])
    }

    func post(appName: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting started \u{2014} record it?"
        content.body = MeetingApps.notificationBody(appName: appName)
        content.categoryIdentifier = Self.category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func withdraw() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard [Self.recordAction, UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier) else { return }
        await onRecord()
    }
}

final class MicrophoneActivityMonitor {
    private let onChange: @MainActor () -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.attach()
            self?.notify()
        }
        attach()
    }

    var isInUse: Bool {
        var running: UInt32 = 0
        return Self.read(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device, into: &running) && running != 0
    }

    private func notify() {
        MainActor.assumeIsolated { onChange() }
    }

    private func attach() {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        }
        deviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
        guard Self.read(kAudioHardwarePropertyDefaultInputDevice, of: AudioObjectID(kAudioObjectSystemObject), into: &device),
              device != kAudioObjectUnknown
        else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        deviceListener = listener
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
