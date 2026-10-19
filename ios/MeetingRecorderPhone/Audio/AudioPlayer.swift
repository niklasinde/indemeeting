import AVFoundation
import Combine
import MediaPlayer
import Observation

/// Plays a meeting's recording through the loopback proxy, which streams and seeks with ranged requests to the Mac.
@Observable @MainActor
final class AudioPlayer {
    struct Track: Equatable {
        var meetingId: Int64
        var title: String
        var duration: Double
    }

    private(set) var track: Track?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var failure: String?
    var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private let proxy: AudioProxy
    private var player: AVPlayer?
    private var observer: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var loading: Task<Void, Never>?

    init(proxy: AudioProxy) { self.proxy = proxy }

    var duration: Double {
        let item = player?.currentItem?.duration.seconds ?? 0
        return item.isFinite && item > 0 ? item : track?.duration ?? 0
    }

    func isCurrent(_ meetingId: Int64) -> Bool { track?.meetingId == meetingId }

    func load(_ track: Track, autoplay: Bool = false, at seconds: Double = 0) {
        if self.track?.meetingId == track.meetingId, player != nil {
            if autoplay { play(at: seconds) }
            return
        }
        stop()
        self.track = track
        failure = nil
        isBuffering = true
        loading = Task { [weak self, proxy] in
            do {
                let url = try await proxy.url(forMeeting: track.meetingId)
                guard let self, !Task.isCancelled, self.track == track else { return }
                self.prepare(url)
                if autoplay { self.play(at: seconds) } else if seconds > 0 { self.seek(to: seconds) }
            } catch {
                self?.failure = "The audio could not be started."
                self?.isBuffering = false
            }
        }
    }

    private func prepare(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.updateNowPlaying()
            }
        }
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.isPlaying = status == .playing
            self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
        }.store(in: &subscriptions)
        item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            if status == .failed {
                self?.failure = "The recording could not be played. Is the Mac reachable?"
                self?.isBuffering = false
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.player?.pause()
            self?.player?.seek(to: .zero)
        }.store(in: &subscriptions)
        setUpRemoteCommands()
    }

    func play(at seconds: Double? = nil) {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if let seconds { seek(to: seconds) }
        player.rate = rate
    }

    func pause() { player?.pause() }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration > 0 ? duration : seconds)
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func stop() {
        loading?.cancel()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        subscriptions.removeAll()
        track = nil
        currentTime = 0
        isPlaying = false
        isBuffering = false
        failure = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying() {
        guard let track else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
    }

    private var commandsReady = false

    private func setUpRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(15) }; return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-15) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }
}
