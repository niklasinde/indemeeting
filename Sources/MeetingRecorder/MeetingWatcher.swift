import AppKit
import Combine
import CoreAudio

@MainActor
final class MeetingWatcher {
    static let enabledKey = "notifyOnMeetingStart"
    static let autoStopKey = "stopWhenMeetingEnds"
    static let automaticKey = "startStopAutomatically"
    static let countdownKey = "recordingCountdownSeconds"

    private let recorder: Recorder
    private let notifier: Notifier
    private let stopRecording: @MainActor () async -> Void
    private var detector = MeetingDetector()
    private var autoStop = AutoStop()
    private var countdown = RecordingCountdown()
    private lazy var banner = CountdownBanner { [weak self] in self?.cancelCountdown() }
    private var monitor: MicrophoneActivityMonitor?
    private var recheck: Task<Void, Never>?
    private var ticker: Timer?
    private var countdownTicker: Timer?
    private var subscription: AnyCancellable?

    init(recorder: Recorder, notifier: Notifier, stopRecording: @escaping @MainActor () async -> Void) {
        self.recorder = recorder
        self.notifier = notifier
        self.stopRecording = stopRecording
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.autoStopKey: true, Self.automaticKey: true,
                                                  Self.countdownKey: RecordingCountdown.defaultLength])
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var automatic: Bool { UserDefaults.standard.bool(forKey: Self.automaticKey) }

    func start() {
        Task { _ = await Permissions.requestNotifications() }
        monitor = MicrophoneActivityMonitor { [weak self] in self?.evaluate() }
        subscription = recorder.$isRecording.sink { [weak self] in
            self?.dropCountdown(recording: $0)
            self?.evaluate(recording: $0)
            self?.watchMeetingEnd(recording: $0)
        }
    }

    private func beginCountdown(_ kind: RecordingCountdown.Kind) {
        let seconds = RecordingCountdown.length(UserDefaults.standard.integer(forKey: Self.countdownKey))
        guard countdown.begin(kind, seconds: seconds, now: Date()) else { return }
        countdownTicker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown() }
        }
        tickCountdown()
    }

    private func tickCountdown() {
        let now = Date()
        if let fired = countdown.tick(now: now) {
            endCountdown()
            switch fired {
            case .start: Task { [recorder] in if !recorder.isRecording { await recorder.start() } }
            case .stop: Task { await stopRecording() }
            }
        } else if let kind = countdown.counting, let remaining = countdown.remaining(now: now) {
            banner.show(RecordingCountdown.text(kind, remaining: remaining))
        }
    }

    private func cancelCountdown() {
        guard let kind = countdown.counting else { return }
        countdown.cancel()
        if kind == .stop { autoStop.waitForNextEnd() }
        endCountdown()
    }

    private func dropCountdown(recording: Bool) {
        if countdown.drop(recording ? .start : .stop) { endCountdown() }
    }

    private func endCountdown() {
        countdownTicker?.invalidate()
        countdownTicker = nil
        banner.hide()
    }

    /// "Keep recording": no auto-stop for the rest of this recording.
    func keepRecording() {
        autoStop.keepRecording()
        notifier.withdrawMeetingEnded()
    }

    private func watchMeetingEnd(recording: Bool) {
        ticker?.invalidate()
        ticker = nil
        notifier.withdrawMeetingEnded()
        guard recording else { return }
        autoStop = AutoStop()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMeetingEnd() }
        }
    }

    private func checkMeetingEnd() {
        guard let lastSound = recorder.lastSound else { return }
        let decision = autoStop.update(enabled: UserDefaults.standard.bool(forKey: Self.autoStopKey),
                                       othersUsingMic: monitor?.isInUseByOthers ?? false,
                                       paused: recorder.isPaused, lastSound: lastSound, now: Date())
        switch decision {
        case .idle: break
        case .ask: if automatic { beginCountdown(.stop) } else { notifier.postMeetingEnded() }
        case .withdraw:
            notifier.withdrawMeetingEnded()
            if countdown.drop(.stop) { endCountdown() }
        case .stop: Task { await stopRecording() }
        }
    }

    private func evaluate(recording: Bool? = nil) {
        let busy = monitor?.isInUse ?? false
        if !busy { notifier.withdrawMeetingStarted() }
        if countdown.micChanged(busy: busy, now: Date()) { endCountdown() }
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
            guard enabled else { break }
            if automatic { beginCountdown(.start) } else { notifier.postMeetingStarted(appName: Self.meetingAppName) }
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
        var address = AudioObjects.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjects.system, &address, .main) { [weak self] _, _ in
            self?.attach()
            self?.notify()
        }
        attach()
    }

    var isInUse: Bool {
        var running: UInt32 = 0
        return AudioObjects.read(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device, into: &running) && running != 0
    }

    /// Whether a process other than this app is taking audio input.
    var isInUseByOthers: Bool {
        let own = getpid()
        return AudioObjects.objects(kAudioHardwarePropertyProcessObjectList, of: AudioObjects.system).contains { process in
            var pid: pid_t = 0
            var running: UInt32 = 0
            return AudioObjects.read(kAudioProcessPropertyPID, of: process, into: &pid) && pid != own
                && AudioObjects.read(kAudioProcessPropertyIsRunningInput, of: process, into: &running) && running != 0
        }
    }

    private func notify() {
        MainActor.assumeIsolated { onChange() }
    }

    private func attach() {
        var address = AudioObjects.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        }
        deviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjects.read(kAudioHardwarePropertyDefaultInputDevice, of: AudioObjects.system, into: &device),
              device != kAudioObjectUnknown
        else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.notify() }
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        deviceListener = listener
    }
}
