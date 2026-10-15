import AVFoundation
import ScreenCaptureKit

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let normalizer = PCMNormalizer()

    func start(into mixer: AudioMixer) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [normalizer] buffer, _ in
            mixer.append(normalizer.samples(from: buffer), from: .microphone)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let normalizer = PCMNormalizer()
    private let queue = DispatchQueue(label: "system-audio")
    private var stream: SCStream?
    private var mixer: AudioMixer?

    func start(into mixer: AudioMixer) async throws {
        self.mixer = mixer
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw PermissionError.screenRecording }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(PCMNormalizer.format.sampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = sampleBuffer.pcmBuffer else { return }
        mixer?.append(normalizer.samples(from: buffer), from: .system)
    }
}

private extension CMSampleBuffer {
    var pcmBuffer: AVAudioPCMBuffer? {
        guard CMSampleBufferIsValid(self),
              let description = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(numSamples), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
