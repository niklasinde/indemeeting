import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Labels finished blocks with Apple Intelligence on this Mac: a category, a short description and a project guess.
/// Runs a batch a little after blocks change and every few minutes; repeats of the same window are answered from the
/// cache without the model.
@MainActor
final class ActivityClassifier {
    static let batchSize = 25
    /// Blocks are classified once they have been closed this long, so an open block is not labelled half-way.
    static let settle: TimeInterval = 60

    private let store: MeetingStore
    private var pending: Task<Void, Never>?
    private var running = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    init(store: MeetingStore) {
        self.store = store
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel(useCase: .contentTagging).isAvailable
        #else
        return false
        #endif
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: MeetingStore.activityDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0) }
        }
        schedule(after: 5)
    }

    private func schedule(after seconds: TimeInterval = 20) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func run() async {
        guard !running, ActivitySettings(.standard).classify, Self.isAvailable else { return }
        running = true
        defer { running = false }
        do {
            let projects = try store.projects()
            let blocks = try store.unclassifiedBlocks(endedBefore: Date().addingTimeInterval(-Self.settle), limit: Self.batchSize)
            for block in blocks {
                let key = ActivityAI.cacheKey(block.key)
                let answer: (category: String, description: String?, project: String?)
                if let cached = try store.cachedClassification(key) {
                    answer = cached
                } else {
                    guard let fresh = try await classify(block, projects: projects) else { continue }
                    answer = fresh
                    try store.cacheClassification(key, category: fresh.category, description: fresh.description, project: fresh.project)
                }
                try store.setClassification(ofBlock: block.id, ActivityAI.classification(
                    category: answer.category, description: answer.description, project: answer.project, projects: projects))
            }
        } catch {
            FileHandle.standardError.write(Data("Activity classification failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func classify(_ block: ActivityBlock, projects: [Project]) async throws -> (category: String, description: String?, project: String?)? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .contentTagging), instructions: ActivityAI.instructions)
        let response = try await session.respond(to: ActivityAI.prompt(for: block, projects: projects), schema: try Self.schema(projects),
                                                 options: GenerationOptions(temperature: 0))
        let content = response.content
        return (try content.value(String.self, forProperty: "category"),
                try content.value(String?.self, forProperty: "description"),
                try content.value(String?.self, forProperty: "project"))
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    private static func schema(_ projects: [Project]) throws -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Activity", properties: [
            .init(name: "category", schema: DynamicGenerationSchema(name: "Category", anyOf: ActivityCategory.allCases.map(\.rawValue))),
            .init(name: "description", description: "At most eight words", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "project", schema: DynamicGenerationSchema(name: "Project", anyOf: ActivityAI.projectChoices(projects))),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }
    #endif
}
