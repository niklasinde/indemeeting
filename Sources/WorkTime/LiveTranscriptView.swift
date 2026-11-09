import AppKit
import SwiftUI

@MainActor
final class LiveTranscriptWindow {
    static let shared = LiveTranscriptWindow()

    private var window: AppWindow?

    func show(_ recorder: Recorder) {
        if window == nil { window = AppWindow { Self.makeWindow(LiveTranscriptView(recorder: recorder, live: recorder.live)) } }
        window?.show()
    }

    static func makeWindow(_ view: LiveTranscriptView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Live Transcript"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 560))
        window.setFrameAutosaveName("LiveTranscript")
        return window
    }
}

struct LiveTranscriptView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var live: LiveTranscription
    @AppStorage(LiveTranscriptLogic.enabledKey) private var enabled = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LiveLines(live: live, placeholder: LiveTranscriptLogic.placeholder(
                enabled: enabled, note: live.note, paused: recorder.isPaused, recording: recorder.isRecording))
        }
        .frame(minWidth: 340, minHeight: 260)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                RecordingStatus(recorder: recorder)
            } else {
                Text("Not recording")
            }
            if let language = live.language, enabled { Text("\u{00B7} \(language.displayName)") }
            Spacer()
            Text("Preview \u{2014} the saved transcript is made after you stop").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The lines heard so far, following the latest one until scrolled away. `leading` is shown above them, and with it
/// the placeholder goes below instead of over the empty list.
struct LiveLines<Leading: View>: View {
    @ObservedObject var live: LiveTranscription
    let placeholder: String
    let inset: EdgeInsets
    let maxWidth: CGFloat
    let leading: Leading
    @State private var following = true
    private let end = "end"

    init(live: LiveTranscription, placeholder: String, inset: EdgeInsets = LiveLinesInset.window, maxWidth: CGFloat = .infinity,
         @ViewBuilder leading: () -> Leading) {
        self.live = live
        self.placeholder = placeholder
        self.inset = inset
        self.maxWidth = maxWidth
        self.leading = leading()
    }

    private var language: MeetingLanguage { live.language ?? .current }
    private var hasLeading: Bool { Leading.self != EmptyView.self }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    leading
                    if hasLeading, live.transcript.isEmpty { placeholderText }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let lines = live.transcript.lines
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(line, named: LiveTranscriptLogic.showsSpeaker(lines, at: index))
                        }
                        Color.clear.frame(height: 1).id(end)
                    }
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(inset)
            }
            .overlay { if !hasLeading, live.transcript.isEmpty { placeholderText.multilineTextAlignment(.center).padding(24) } }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        following = true
                        withAnimation { proxy.scrollTo(end, anchor: .bottom) }
                    }
                    .padding(12)
                }
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                guard phase == .idle, oldPhase != .idle else { return }
                let geometry = context.geometry
                following = LiveTranscriptLogic.isAtBottom(offset: geometry.contentOffset.y, visibleHeight: geometry.containerSize.height,
                                                           contentHeight: geometry.contentSize.height)
            }
            .onAppear { proxy.scrollTo(end, anchor: .bottom) }
            .onChange(of: live.transcript) {
                if following { proxy.scrollTo(end, anchor: .bottom) }
            }
        }
    }

    private var placeholderText: some View {
        Text(placeholder)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func row(_ line: LiveLine, named: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if named {
                Text(line.speaker.name(in: language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(line.speaker == .you ? Color.accentColor : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ProcessingLogic.timestamp(line.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(line.text)
                    .foregroundStyle(line.isFinal && !line.isPending ? .primary : .secondary)
                    .italic(!line.isFinal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension LiveLines where Leading == EmptyView {
    init(live: LiveTranscription, placeholder: String, inset: EdgeInsets = LiveLinesInset.window, maxWidth: CGFloat = .infinity) {
        self.init(live: live, placeholder: placeholder, inset: inset, maxWidth: maxWidth) { EmptyView() }
    }
}

enum LiveLinesInset {
    static let window = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
}
