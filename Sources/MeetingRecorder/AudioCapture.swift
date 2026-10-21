import AVFoundation
import CoreAudio

/// A fresh engine per recording: once released, the input device (and a Bluetooth headset's call profile) is let go.
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private let normalizer = PCMNormalizer()

    func start(into mixer: AudioMixer) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [normalizer] buffer, _ in
            mixer.append(normalizer.samples(from: buffer), from: .microphone)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
    }
}

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "System audio: \(operation) failed (\(status))." }
}

/// Records everything the Mac plays (the other participants) through a Core Audio process tap.
/// Needs the "System Audio Recording Only" permission, not Screen Recording.
/// The app plays no audio, so nothing is excluded; excluding our own process stops the IOProc from running.
final class SystemAudioCapture {
    private let normalizer = PCMNormalizer()
    private let queue = DispatchQueue(label: "system-audio")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?

    func start(into mixer: AudioMixer) throws {
        do {
            try startTap(into: mixer)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(into mixer: AudioMixer) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("create tap", AudioHardwareCreateProcessTap(description, &tap))

        var streamDescription = AudioStreamBasicDescription()
        guard AudioObjects.read(kAudioTapPropertyFormat, of: tap, into: &streamDescription),
              let format = AVAudioFormat(streamDescription: &streamDescription)
        else { throw CoreAudioError(operation: "read tap format", status: kAudioHardwareUnspecifiedError) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Recorder System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        try check("create IOProc", AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [normalizer] _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            mixer.append(normalizer.samples(from: buffer), from: .system)
        })
        try check("start device", AudioDeviceStart(device, proc))
    }

    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ operation: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    }
}

enum AudioObjects {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func objects(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
