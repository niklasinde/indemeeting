import AVFoundation

final class PCMNormalizer {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?

    func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return [] }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

enum AudioSource: Int, CaseIterable {
    case microphone
    case system
}

struct LevelMeter {
    static let silenceThreshold = 0.001

    private(set) var count = 0
    private var sumOfSquares = 0.0

    mutating func add(_ samples: [Float]) {
        sumOfSquares += samples.reduce(0) { $0 + Double($1 * $1) }
        count += samples.count
    }

    var rms: Double { count == 0 ? 0 : (sumOfSquares / Double(count)).squareRoot() }
    var isSilent: Bool { rms < Self.silenceThreshold }
}

/// Sums the sources sample-by-sample and writes the result as AAC. A source
/// that stopped delivering (e.g. no system audio) no longer holds back the other.
/// The file is written under a `.recording.m4a` name and moved to `url` once finalized.
final class AudioMixer {
    private static let staleAfter: TimeInterval = 1
    private static let flushInterval: DispatchTimeInterval = .milliseconds(100)

    let url: URL
    private let partialURL: URL
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "mixer")
    private var timer: DispatchSourceTimer?
    private var written = 0
    private var pending = AudioSource.allCases.map { _ in [Float]() }
    private var lastSeen = AudioSource.allCases.map { _ in Date.distantPast }
    private var meters = AudioSource.allCases.map { _ in LevelMeter() }

    init(url: URL) throws {
        self.url = url
        partialURL = RecordingLogic.partialURL(for: url)
        file = try AVAudioFile(
            forWriting: partialURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: PCMNormalizer.format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush(final: false) }
        timer.resume()
        self.timer = timer
    }

    func append(_ samples: [Float], from source: AudioSource) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard self.file != nil else { return }
            self.pending[source.rawValue].append(contentsOf: samples)
            self.lastSeen[source.rawValue] = Date()
            self.meters[source.rawValue].add(samples)
        }
    }

    var framesWritten: Int { queue.sync { written } }

    func level(of source: AudioSource) -> LevelMeter { queue.sync { meters[source.rawValue] } }

    /// Writes what is pending, closes the file and moves it to `url`.
    /// Returns where the recording ended up (the partial name if the move failed).
    @discardableResult
    func finish() -> URL {
        queue.sync {
            timer?.cancel()
            timer = nil
            flush(final: true)
            if #available(macOS 15, *) { file?.close() }
            file = nil
        }
        do {
            try FileManager.default.moveItem(at: partialURL, to: url)
            return url
        } catch {
            return partialURL
        }
    }

    private func flush(final: Bool) {
        let now = Date()
        let active = pending.indices.filter { now.timeIntervalSince(lastSeen[$0]) < Self.staleAfter }
        let waitingOn = active.isEmpty ? Array(pending.indices) : active
        let count = (final ? Array(pending.indices) : waitingOn).map { pending[$0].count }
            .reduce(final ? 0 : Int.max, final ? max : min)
        guard count > 0, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: PCMNormalizer.format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0]
        else { return }

        for frame in 0..<count { out[frame] = 0 }
        for index in pending.indices {
            let take = min(count, pending[index].count)
            for frame in 0..<take { out[frame] += pending[index][frame] }
            pending[index].removeFirst(take)
        }
        for frame in 0..<count { out[frame] = max(-1, min(1, out[frame])) }
        buffer.frameLength = AVAudioFrameCount(count)
        try? file.write(from: buffer)
        written += count
    }
}
