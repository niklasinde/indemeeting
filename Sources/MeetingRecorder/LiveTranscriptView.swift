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
    @State private var following = true
    private let end = "end"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let lines = live.transcript.lines
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(line, named: LiveTranscriptLogic.showsSpeaker(lines, at: index))
                        }
                        Color.clear.frame(height: 1).id(end)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay { if live.transcript.isEmpty { placeholder } }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button("Jump to Latest", systemImage: "arrow.down") {
                            following = true
                            withAnimation { proxy.scrollTo(end, anchor: .bottom) }
                        }
                        .padding(12)
                    }
                }
                .onScrollPhaseChange { _, phase, context in
                    guard phase == .idle else { return }
                    let geometry = context.geometry
                    following = LiveTranscriptLogic.isAtBottom(offset: geometry.contentOffset.y, visibleHeight: geometry.containerSize.height,
                                                               contentHeight: geometry.contentSize.height)
                }
                .onChange(of: live.transcript) {
                    if following { proxy.scrollTo(end, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 260)
    }

    private var language: MeetingLanguage { live.language ?? .current }

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

    private var placeholder: some View {
        Text(placeholderText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
    }

    private var placeholderText: String {
        if !enabled { return "Live transcription is off. Turn it on in Settings \u{2192} Meetings." }
        if let note = live.note { return note }
        if recorder.isPaused { return "Paused" }
        return recorder.isRecording ? "Listening\u{2026} Text appears here as people speak." : "Start a recording to see what is said."
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
                    .foregroundStyle(line.isFinal ? .primary : .secondary)
                    .italic(!line.isFinal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
