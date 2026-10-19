import Foundation
import Observation

@Observable @MainActor
final class MeetingsModel {
    let first: Resource<PhoneMeetingList>
    private(set) var extra: [PhoneMeetingSummary] = []
    private(set) var nextBefore: Date?
    private(set) var results: [PhoneMeetingSummary]?
    private(set) var searchIsLocal = false
    private(set) var searchError: PhoneNetworkError?
    private(set) var isLoadingMore = false
    private let model: AppModel

    static let pageSize = 50

    init(model: AppModel) {
        self.model = model
        first = Resource(model: model)
    }

    var items: [PhoneMeetingSummary] { (first.value?.meetings ?? []) + extra }

    func refresh() async {
        await first.load("meetings", .get("/v1/meetings", [URLQueryItem(name: "limit", value: String(Self.pageSize))]))
        if first.error == nil {
            extra = []
            nextBefore = first.value?.nextBefore
        } else if extra.isEmpty {
            nextBefore = first.value?.nextBefore
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoadingMore, first.error == nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let query = [URLQueryItem(name: "limit", value: String(Self.pageSize)), URLQueryItem(name: "before", value: Self.iso(before))]
        guard let page: PhoneMeetingList = try? await model.request(.get("/v1/meetings", query)) else { return }
        let known = Set(items.map(\.id))
        extra += page.meetings.filter { !known.contains($0.id) }
        nextBefore = page.nextBefore
    }

    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = nil
            searchError = nil
            return
        }
        do {
            let list: PhoneMeetingList = try await model.request(.get("/v1/meetings", [URLQueryItem(name: "query", value: query),
                                                                                       URLQueryItem(name: "limit", value: "100")]))
            results = list.meetings
            searchIsLocal = false
            searchError = nil
        } catch is CancellationError {
        } catch let error as PhoneNetworkError {
            results = Self.localMatches(items, query)
            searchIsLocal = true
            searchError = error
        } catch {}
    }

    /// Title search over what is already on the phone, for when the Mac cannot be asked.
    nonisolated static func localMatches(_ items: [PhoneMeetingSummary], _ query: String) -> [PhoneMeetingSummary] {
        let words = query.lowercased().split(separator: " ")
        return items.filter { item in words.allSatisfy { item.title.lowercased().contains($0) } }
    }

    nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
