import AVFoundation

final class PCMNormalizer {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat = PCMNormalizer.format) {
        self.format = format
    }

    func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter else { return [] }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

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

    var stemName: String { self == .microphone ? "mic" : "system" }
}

struct LevelMeter {
    static let silenceThreshold = 0.001
    /// Quieter than speech: what auto-stop counts as silence.
    static let soundThreshold = 0.003

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
/// With `stems`, each source is also written on its own, padded with silence so it lines up with the mix.
final class AudioMixer {
    /// AAC as every recording is written; appended meetings are re-encoded with the same settings.
    static let encoderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: PCMNormalizer.format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
    ]

    private static let staleAfter: TimeInterval = 1
    private static let flushInterval: DispatchTimeInterval = .milliseconds(100)

    let url: URL
    private let mix: AudioTrackWriter
    private let stems: [AudioTrackWriter]
    private let queue = DispatchQueue(label: "mixer")
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var written = 0
    private var paused = false
    private var heard = Date()
    private var pending = AudioSource.allCases.map { _ in [Float]() }
    private var lastSeen = AudioSource.allCases.map { _ in Date.distantPast }
    private var meters = AudioSource.allCases.map { _ in LevelMeter() }

    init(url: URL, stems: Bool = false) throws {
        self.url = url
        mix = try AudioTrackWriter(url: url)
        self.stems = stems ? try AudioSource.allCases.map { try AudioTrackWriter(url: RecordingLogic.stemURL(for: url, source: $0)) } : []
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush(final: false) }
        timer.resume()
        self.timer = timer
    }

    func append(_ samples: [Float], from source: AudioSource) {
        guard !samples.isEmpty else { return }
        queue.async {
            guard !self.finished, !self.paused else { return }
            self.pending[source.rawValue].append(contentsOf: samples)
            self.lastSeen[source.rawValue] = Date()
            self.meters[source.rawValue].add(samples)
            var chunk = LevelMeter()
            chunk.add(samples)
            if chunk.rms >= LevelMeter.soundThreshold { self.heard = Date() }
        }
    }

    /// Writes what is pending and drops everything delivered until `resume()`, so the file has no gap.
    func pause() {
        queue.sync {
            flush(final: true)
            paused = true
        }
    }

    func resume() {
        queue.sync {
            paused = false
            heard = Date()
        }
    }

    var framesWritten: Int { queue.sync { written } }

    /// When either source last had more than silence in it (or recording started or resumed).
    var lastSound: Date { queue.sync { heard } }

    func level(of source: AudioSource) -> LevelMeter { queue.sync { meters[source.rawValue] } }

    /// Writes what is pending, closes the files and moves them to their final names.
    /// Returns where the recording ended up (the partial name if the move failed).
    @discardableResult
    func finish() -> URL {
        queue.sync {
            timer?.cancel()
            timer = nil
            flush(final: true)
            finished = true
        }
        stems.forEach { $0.finish() }
        return mix.finish()
    }

    private func flush(final: Bool) {
        guard !finished else { return }
        let now = Date()
        let active = pending.indices.filter { now.timeIntervalSince(lastSeen[$0]) < Self.staleAfter }
        let waitingOn = active.isEmpty ? Array(pending.indices) : active
        let count = (final ? Array(pending.indices) : waitingOn).map { pending[$0].count }
            .reduce(final ? 0 : Int.max, final ? max : min)
        guard count > 0 else { return }

        var mixed = [Float](repeating: 0, count: count)
        for index in pending.indices {
            let take = min(count, pending[index].count)
            let samples = pending[index].prefix(take)
            for (frame, sample) in samples.enumerated() { mixed[frame] += sample }
            if !stems.isEmpty { stems[index].write(Array(samples) + [Float](repeating: 0, count: count - take)) }
            pending[index].removeFirst(take)
        }
        mix.write(mixed.map { max(-1, min(1, $0)) })
        written += count
    }
}

/// One AAC file written under its `.recording.m4a` name and moved to `url` when finished.
final class AudioTrackWriter {
    let url: URL
    private let partialURL: URL
    private var file: AVAudioFile?

    init(url: URL) throws {
        self.url = url
        partialURL = RecordingLogic.partialURL(for: url)
        file = try AVAudioFile(forWriting: partialURL, settings: AudioMixer.encoderSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: PCMNormalizer.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0]
        else { return }
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try? file.write(from: buffer)
    }

    @discardableResult
    func finish() -> URL {
        file?.close()
        file = nil
        do {
            try FileManager.default.moveItem(at: partialURL, to: url)
            return url
        } catch {
            return partialURL
        }
    }
}
