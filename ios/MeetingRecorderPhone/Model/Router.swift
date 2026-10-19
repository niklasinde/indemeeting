import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case meetings, activity, github, chat, settings
}

struct MeetingRoute: Hashable {
    var id: Int64
    var title: String?
}

/// Which tab is open and which meeting is on screen, so a citation in a chat can open the meeting and seek in it.
@Observable @MainActor
final class Router {
    var tab = AppTab.meetings
    var meetingPath: [MeetingRoute] = []
    /// A position to play from once the meeting has loaded.
    var pendingSeek: [Int64: Double] = [:]

    func open(meeting id: Int64, title: String? = nil, seek: Double? = nil) {
        if let seek { pendingSeek[id] = seek }
        tab = .meetings
        if meetingPath.last?.id != id { meetingPath = [MeetingRoute(id: id, title: title)] }
    }
}
