import Foundation
import Observation

@Observable @MainActor
final class ActivityModel {
    enum Mode: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week"
        var id: String { rawValue }
    }

    var mode = Mode.day
    var date = Date()
    let resource: Resource<PhoneActivity>
    private let calendar = Calendar.current

    init(model: AppModel) { resource = Resource(model: model) }

    var key: String { "activity.\(mode == .day ? "day" : "week").\(PhoneFormat.dayString(date, calendar: calendar))" }

    var request: PhoneRequest {
        let day = PhoneFormat.dayString(date, calendar: calendar)
        return mode == .day ? .get("/v1/activity/day", [URLQueryItem(name: "date", value: day)])
            : .get("/v1/activity/week", [URLQueryItem(name: "start", value: day)])
    }

    func load() async { await resource.load(key, request) }

    func step(_ direction: Int) {
        date = calendar.date(byAdding: .day, value: direction * (mode == .day ? 1 : 7), to: date) ?? date
    }

    func goToToday() { date = Date() }

    var isCurrent: Bool {
        mode == .day ? calendar.isDateInToday(date) : calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
    }

    var canStepForward: Bool { !isCurrent && date < Date() }

    var title: String {
        if mode == .day { return PhoneFormat.dayTitle(date, calendar: calendar) }
        guard let activity = resource.value, let first = activity.days.first.flatMap({ PhoneFormat.day(from: $0.date, calendar: calendar) }),
              let last = activity.days.last.flatMap({ PhoneFormat.day(from: $0.date, calendar: calendar) }) else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) \u{2013} \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    func select(day text: String) {
        guard let day = PhoneFormat.day(from: text, calendar: calendar) else { return }
        date = day
        mode = .day
    }
}
