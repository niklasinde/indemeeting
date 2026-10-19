import Foundation
import Observation

/// One thing fetched from the Mac: shows the cached copy at once, replaces it when the Mac answers, and keeps it with an
/// error and the time of the last sync when the Mac does not.
@Observable @MainActor
final class Resource<Value: Codable & Sendable> {
    private(set) var value: Value?
    private(set) var syncedAt: Date?
    private(set) var error: PhoneNetworkError?
    private(set) var isLoading = false
    private var key: String?

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    var isStale: Bool { error != nil && value != nil }

    func load(_ key: String, _ request: PhoneRequest, idleTimeout: TimeInterval = 20) async {
        if self.key != key {
            self.key = key
            let cached = model.cache?.get(Value.self, for: key)
            value = cached?.value
            syncedAt = cached?.fetched
            error = nil
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh: Value = try await model.request(request, idleTimeout: idleTimeout)
            guard self.key == key else { return }
            value = fresh
            syncedAt = Date()
            error = nil
            model.cache?.put(fresh, for: key)
        } catch is CancellationError {
        } catch let failure as PhoneNetworkError {
            guard self.key == key else { return }
            error = failure
        } catch {
            self.error = .badResponse
        }
    }

    func replace(_ newValue: Value, key: String) {
        self.key = key
        value = newValue
        syncedAt = Date()
        error = nil
        model.cache?.put(newValue, for: key)
    }
}
