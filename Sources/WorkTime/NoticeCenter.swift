import AppKit
import UserNotifications

/// The notifications agents send through `notify`: shown or scheduled with the system, kept in `notifications.json` and listed
/// in the notch bar until the user opens or dismisses them.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()
    static let grace: TimeInterval = 2
    @Published private(set) var notices: [AgentNotice] = []
    private var recent: [AgentNotice] = []
    private var file: URL?
    private var timer: Timer?

    var pending: [AgentNotice] { NoticeLogic.pending(notices) }
    var waiting: [AgentNotice] { NoticeLogic.waiting(notices) }

    func start(file: URL = AppPaths.notices) {
        self.file = file
        notices = NoticeLogic.decode(try? Data(contentsOf: file))
        fireDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
    }

    func handle(_ request: NoticeRequest) -> NoticeReply {
        func reply(_ ok: Bool, _ notice: String?, _ message: String) -> NoticeReply {
            NoticeReply(id: request.id, ok: ok, notice: notice, message: message)
        }
        let now = Date()
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, nil, "The request is too old.") }
        switch request.action {
        case .cancel:
            guard let id = request.cancel else { return reply(false, nil, "id is required.") }
            if let problem = NoticeLogic.cancelProblem(id, in: notices, by: request.source) { return reply(false, id, problem) }
            dismiss(id)
            return reply(true, id, "Cancelled the notification \(id).")
        case .notify:
            guard var notice = request.notice, !notice.title.isEmpty, notice.title.count <= NoticeLogic.titleLimit else {
                return reply(false, nil, "The notification has no usable title.")
            }
            notice.source = request.source
            notice.source.title = request.source.label(titles: titles())
            recent.removeAll { now.timeIntervalSince($0.created) >= NoticeLogic.collapseWindow }
            var message = notice.at == nil ? "Shown to the user." : "Scheduled."
            switch NoticeLogic.admit(notice, existing: notices, recent: recent, now: now) {
            case .reject(let problem): return reply(false, nil, problem)
            case .collapse(let id): return reply(true, id, "The same notification was shown moments ago, so it was not shown again.")
            case .replace(let id):
                notice.id = id
                notices.removeAll { $0.id == id }
                message = "Updated the notification already scheduled for that time."
            case .add: break
            }
            recent.append(notice)
            notices.append(notice)
            Notifier.postNotice(notice)
            save()
            return reply(true, notice.id, message)
        }
    }

    /// Opens what the notification links to (or the agent that sent it) and takes it off the list.
    func open(_ id: String) {
        guard let notice = notices.first(where: { $0.id == id }) else { return }
        dismiss(id)
        switch notice.link.flatMap(NoticeLogic.link) {
        case .pullRequest(let target)?: AgentModel.openPullRequestLink?(target)
        case .agent(let key)?: AgentHub.shared.show(key)
        case .jira(let key)?:
            if let url = JiraModel.shared.site.flatMap({ JiraLogic.browseURL(site: $0, key: key) }) { NSWorkspace.shared.open(url) }
        case .web(let url)?: NSWorkspace.shared.open(url)
        case nil: if let agent = notice.source.agent { AgentHub.shared.show(agent) }
        }
    }

    /// Takes a notification off the list, and a scheduled one off the system's schedule too.
    func dismiss(_ id: String) {
        notices.removeAll { $0.id == id }
        Notifier.withdrawNotice(id)
        save()
    }

    /// Marks scheduled notifications whose time came as shown, or as missed when far behind; posts those the system has not.
    private func fireDue() {
        let due = NoticeLogic.due(notices, now: Date().addingTimeInterval(-Self.grace))
        guard !due.fire.isEmpty || !due.missed.isEmpty else { return }
        for index in notices.indices {
            if due.fire.contains(notices[index].id) { notices[index].state = .shown }
            if due.missed.contains(notices[index].id) { notices[index].state = .missed }
        }
        save()
        let fired = notices.filter { due.fire.contains($0.id) }
        Task {
            let delivered = Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
            for notice in fired where !delivered.contains(NoticeLogic.identifier(notice.id)) {
                var now = notice
                now.at = nil
                Notifier.postNotice(now)
            }
        }
    }

    /// The agents' titles by key, to name who sent something.
    func titles() -> [String: String] {
        Dictionary(AgentStateWriter.shared.states().map { ($0.key, $0.title) }) { first, _ in first }
    }

    private func save() {
        guard let file else { return }
        let data = NoticeLogic.encode(notices)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    #if DEBUG
    func showSample(_ notices: [AgentNotice]) { self.notices = notices }
    #endif
}
