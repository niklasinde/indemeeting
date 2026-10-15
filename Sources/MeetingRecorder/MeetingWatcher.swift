import AppKit
import Combine
import CoreAudio

@MainActor
final class MeetingWatcher {
    static let enabledKey = "notifyOnMeetingStart"

    private let recorder: Recorder
    private let notifier: Notifier
    private var detector = MeetingDetector()
    private var monitor: MicrophoneActivityMonitor?
    private var recheck: Task<Void, Never>?
    private var subscription: AnyCancellable?

    init(recorder: Recorder, notifier: Notifier) {
        self.recorder = recorder
        self.notifier = notifier
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
        if !busy { notifier.withdrawMeetingStarted() }
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
            if enabled { notifier.postMeetingStarted(appName: Self.meetingAppName) }
        }
    }

    private static var meetingAppName: String? {
        let workspace = NSWorkspace.shared
        return MeetingApps.name(frontmost: workspace.frontmostApplication?.bundleIdentifier,
                                running: workspace.runningApplications.compactMap(\.bundleIdentifier))
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
