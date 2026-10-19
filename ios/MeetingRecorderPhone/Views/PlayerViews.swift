import SwiftUI

/// Scrubber, skip buttons and speed for the recording that is loaded.
struct PlayerControls: View {
    let player: AudioPlayer
    @State private var scrubbing = false
    @State private var scrubTime = 0.0

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { scrubbing ? scrubTime : player.currentTime }, set: { scrubTime = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrubTime) }
            }
            .accessibilityLabel("Position")
            .accessibilityValue(PhoneFormat.clock(player.currentTime))
            HStack {
                Text(PhoneFormat.clock(scrubbing ? scrubTime : player.currentTime))
                Spacer()
                Text("-" + PhoneFormat.clock(max(player.duration - (scrubbing ? scrubTime : player.currentTime), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Menu {
                    Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                        ForEach(AudioPlayer.rates, id: \.self) { Text(Self.rateText($0)).tag($0) }
                    }
                } label: {
                    Text(Self.rateText(player.rate)).font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 52)
                }
                .accessibilityLabel("Playback speed")
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                    .accessibilityLabel("Back 15 seconds")
                Button { player.toggle() } label: {
                    Group {
                        if player.isBuffering && !player.isPlaying { ProgressView() } else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    }
                    .font(.title)
                    .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
                    .accessibilityLabel("Forward 15 seconds")
                Button { player.stop() } label: { Image(systemName: "xmark.circle").font(.title3) }
                    .accessibilityLabel("Close player")
            }
            .buttonStyle(.plain)
            if let failure = player.failure { Text(failure).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    static func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))\u{00D7}" : String(format: "%g\u{00D7}", rate)
    }
}

/// The bar above the tab bar while a recording is loaded.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router

    var body: some View {
        let player = appModel.player
        if let track = player.track {
            HStack(spacing: 12) {
                Button { router.open(meeting: track.meetingId, title: track.title) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(PhoneFormat.clock(player.currentTime)) / \(PhoneFormat.clock(player.duration))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the meeting")
                Spacer(minLength: 0)
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                Button { player.toggle() } label: {
                    if player.isBuffering && !player.isPlaying { ProgressView() } else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("Forward 15 seconds")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .padding(.horizontal, 16)
        }
    }
}
