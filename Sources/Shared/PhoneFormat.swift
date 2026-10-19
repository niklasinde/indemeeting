import Foundation

/// Pure text and grouping logic the iPhone app needs; Foundation only so both targets compile it.
enum PhoneFormat {
    static let seekScheme = "mrseek"

    /// `33 min`, `1 h 05 min`.
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(max(minutes, seconds > 0 ? 1 : 0)) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// `4:07`, `1:02:03`.
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).day().month(.wide)
        return date.formatted(sameYear ? style : style.year())
    }

    /// `YYYY-MM-DD`, the day format of the activity endpoints.
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func day(from text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    struct DayGroup<Element> {
        var day: Date
        var title: String
        var items: [Element]
    }

    /// Consecutive items on the same day share a group; the order of `items` is kept.
    static func groupByDay<Element>(_ items: [Element], date: (Element) -> Date, now: Date = Date(),
                                    calendar: Calendar = .current, locale: Locale = .current) -> [DayGroup<Element>] {
        var groups: [DayGroup<Element>] = []
        for item in items {
            if let last = groups.last, calendar.isDate(last.day, inSameDayAs: date(item)) {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(DayGroup(day: date(item), title: dayTitle(date(item), now: now, calendar: calendar, locale: locale), items: [item]))
            }
        }
        return groups
    }

    static func shortSpeakers(_ speakers: [String], limit: Int = 3) -> [String] {
        speakers.count > limit ? Array(speakers.prefix(limit)) + ["+\(speakers.count - limit)"] : speakers
    }

    /// The summary of a meeting as Markdown, for sharing.
    static func markdown(for meeting: PhoneMeetingDetail, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var lines = ["# \(meeting.summaryTitle ?? meeting.title)"]
        let when = meeting.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).day().month(.wide).year().hour().minute())
        lines.append("*\(when)\(meeting.duration.map { " \u{00B7} " + duration($0) } ?? "")*")
        for topic in meeting.topics {
            lines += ["", "## \(topic.title)"] + topic.points.map { "- \($0)" }
        }
        if !meeting.actionItems.isEmpty {
            lines += ["", "## Action items"]
            lines += meeting.actionItems.map { "- [\($0.done ? "x" : " ")] \($0.owner.map { "\($0): " } ?? "")\($0.text)" }
        }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines += ["", "## Notes", notes] }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Times in answers

    private static let timePattern = try! NSRegularExpression(pattern: #"(?<![\d:])(\d{1,2}):([0-5]\d)(?::([0-5]\d))?(?![\d:])"#)

    /// Turns every `mm:ss` or `h:mm:ss` in an answer into a Markdown link the app handles as a seek.
    static func linkTimes(in text: String) -> String {
        let source = text as NSString
        var result = ""
        var position = 0
        for match in timePattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let numbers = (1...3).compactMap { match.range(at: $0).location == NSNotFound ? nil : Double(source.substring(with: match.range(at: $0))) }
            let seconds = numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
            result += "[\(source.substring(with: match.range))](\(seekScheme)://\(Int(seconds)))"
            position = match.range.location + match.range.length
        }
        return result + source.substring(from: position)
    }

    static func seekSeconds(_ url: URL) -> Double? {
        url.scheme == seekScheme ? url.host.flatMap(Double.init) : nil
    }

    // MARK: Activity

    static func percent(_ part: Double, of total: Double) -> Double {
        total > 0 ? min(max(part / total, 0), 1) : 0
    }

    // MARK: Pairing input

    /// What the user typed as the Mac's address: `host`, `host:port` or `[::1]:port`, with an optional default port.
    static func hostAndPort(_ text: String, defaultPort: Int = PhoneAPI.defaultPort) -> (host: String, port: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (trimmed, defaultPort)
        case 2:
            guard !parts[0].isEmpty, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
            return (String(parts[0]), port)
        default: return nil
        }
    }
}
