import Combine
import Foundation

/// Deletes the audio of processed recordings: after each processing job, at launch and every few hours.
@MainActor
final class AudioCleaner {
    static let interval: TimeInterval = 3 * 3600

    private let recorder: Recorder
    private let processor: MeetingProcessor
    private let store: MeetingStore
    private let folder: URL
    private var subscription: AnyCancellable?
    private var timer: Timer?

    init(recorder: Recorder, processor: MeetingProcessor, store: MeetingStore, folder: URL = AppPaths.recordings) {
        self.recorder = recorder
        self.processor = processor
        self.store = store
        self.folder = folder
    }

    func start() {
        subscription = processor.$processing.removeDuplicates().filter { $0 == nil }.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sweep() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    var busyFiles: Set<String> {
        processor.busyFiles.union([recorder.meeting, processor.processing].compactMap { $0?.lastPathComponent })
    }

    func sweep() {
        guard store.isAvailable else { return }
        do {
            try AudioRetention.sweep(store: store, folder: folder, now: Date(), busy: busyFiles)
        } catch {
            FileHandle.standardError.write(Data("Audio cleanup failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
