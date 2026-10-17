import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ActivityMode: String, CaseIterable {
    case day = "Day"
    case week = "Week"
}

/// The blocks, projects and rules shown for the chosen day or week.
@MainActor
final class ActivityModel: ObservableObject {
    @Published var date = Date() { didSet { load() } }
    @Published var mode = ActivityMode.day { didSet { load() } }
    @Published private(set) var blocks: [ActivityBlock] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var rules: [ProjectRule] = []
    @Published var editing: ActivityBlock?
    @Published var selected: Int64?
    @Published var copied = false

    let store: MeetingStore
    let tracker: ActivityTracker
    private var observer: NSObjectProtocol?
    private var icons: [String: NSImage] = [:]

    init(store: MeetingStore, tracker: ActivityTracker) {
        self.store = store
        self.tracker = tracker
    }

    var day: Range<Date> { ActivityLogic.day(containing: date) }
    var week: [Range<Date>] { ActivityLogic.week(containing: date) }
    var range: Range<Date> { mode == .day ? day : week.first!.lowerBound..<week.last!.upperBound }
    var isToday: Bool { Calendar.current.isDateInToday(date) }

    func start() {
        defer { load() }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: MeetingStore.activityDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    func load() {
        blocks = (try? store.blocks(in: range)) ?? []
        projects = (try? store.projects()) ?? []
        rules = (try? store.rules()) ?? []
    }

    func shift(_ offset: Int) {
        date = Calendar.current.date(byAdding: mode == .day ? .day : .weekOfYear, value: offset, to: date) ?? date
    }

    func project(of block: ActivityBlock) -> Project? { ActivityLogic.project(for: block, rules: rules, projects: projects) }

    func setProject(_ projectID: Int64?, of block: ActivityBlock) {
        perform { try store.setProject(ofBlock: block.id, projectID) }
    }

    func addRule(_ field: RuleField, pattern: String, project: Int64) {
        perform { try store.addRule(project: project, field: field, pattern: pattern) }
    }

    func isPrivate(_ block: ActivityBlock) -> Bool { tracker.settings.action(for: block.category) != .keep }

    func delete(_ block: ActivityBlock) {
        tracker.discard { $0.id == block.id }
        perform { try store.delete(blockIDs: [block.id]) }
    }

    func deleteAndStopTracking(_ block: ActivityBlock) {
        if let app = block.key.appName, !tracker.settings.excludes(appName: app, bundle: block.key.appBundle) {
            tracker.setExcludedApps(tracker.settings.excludedApps + [app])
        }
        delete(block)
    }

    func deleteHost(of block: ActivityBlock) {
        guard let host = block.host else { return }
        let day = ActivityLogic.day(containing: block.start)
        tracker.discard { $0.host == host && $0.seconds(in: day) > 0 }
        perform { try store.deleteMatching(host: host, on: block.start) }
    }

    /// Deletes everything since `seconds` ago, including the open block.
    func deleteLast(_ seconds: TimeInterval) {
        delete(Date().addingTimeInterval(-seconds)..<Date.distantFuture)
    }

    func deleteDay() { delete(day) }

    private func delete(_ range: Range<Date>) {
        tracker.discard { $0.seconds(in: range) > 0 }
        perform { try store.delete(from: range.lowerBound, to: range.upperBound) }
    }

    func addProject(_ name: String) -> Project? {
        var project: Project?
        perform { project = try store.addProject(name) }
        return project
    }

    func icon(for block: ActivityBlock) -> NSImage? {
        guard let bundle = block.key.appBundle else { return nil }
        if let icon = icons[bundle] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundle] = icon
        return icon
    }

    var contextMarkdown: String {
        let range = mode == .day ? day : self.range
        return ActivityLogic.contextMarkdown(blocks: blocks, meetings: (try? store.meetingLines(in: range)) ?? [], range: range,
                                             rules: rules, projects: projects)
    }

    func copyContext() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextMarkdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    func exportWeek(markdown: Bool) {
        let days = week
        let blocks = (try? store.blocks(in: days.first!.lowerBound..<days.last!.upperBound)) ?? []
        let report = ActivityLogic.WeekReport(days: days, blocks: blocks, rules: rules, projects: projects)
        let panel = NSSavePanel()
        panel.title = "Export Week"
        let week = Calendar.current.component(.weekOfYear, from: date)
        panel.nameFieldStringValue = "Activity-week-\(week)." + (markdown ? "md" : "csv")
        panel.allowedContentTypes = [markdown ? UTType(filenameExtension: "md") ?? .plainText : .commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try (markdown ? ActivityLogic.markdown(report) : ActivityLogic.csv(report)).write(to: url, atomically: true, encoding: .utf8) }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { NSAlert(error: error).runModal() }
    }
}

struct ActivityView: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var tracker: ActivityTracker
    @State private var confirmingDayDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !tracker.settings.enabled || !tracker.accessibilityGranted { setupNotice }
            ScrollView {
                Group {
                    switch model.mode {
                    case .day: DayView(model: model)
                    case .week: WeekView(model: model)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RecordingDetail.gutter)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.system(size: 20, weight: .medium))
                Spacer()
                Button { model.copyContext() } label: {
                    Label(model.copied ? "Copied" : "Copy Context", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copies a Markdown summary of this \(model.mode.rawValue.lowercased()) for pasting into Claude")
                if model.mode == .day { deleteMenu }
            }
            HStack(spacing: 8) {
                Text(subtitle)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            HStack(spacing: 2) {
                ForEach(ActivityMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { model.mode = mode }
                        .buttonStyle(PillButtonStyle(selected: model.mode == mode))
                }
                Spacer()
                HStack(spacing: 4) {
                    Button { model.shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { model.date = Date() }.disabled(model.isToday)
                    Button { model.shift(1) } label: { Image(systemName: "chevron.right") }.disabled(model.isToday)
                    DatePicker("Date", selection: $model.date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(width: 110)
                }
                .controlSize(.small)
            }
            .padding(.top, 18)
            .padding(.leading, -8)
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var deleteMenu: some View {
        Menu {
            Button("Delete Last 15 Minutes") { model.deleteLast(15 * 60) }.disabled(!model.isToday)
            Button("Delete Last Hour") { model.deleteLast(3600) }.disabled(!model.isToday)
            Divider()
            Button("Delete This Day\u{2026}") { confirmingDayDelete = true }.disabled(model.blocks.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Delete activity")
        .alert("Delete all activity on \(model.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))?", isPresented: $confirmingDayDelete) {
            Button("Delete", role: .destructive) { model.deleteDay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every block of the day is removed from the database.")
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .day:
            return model.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            let days = model.week
            return "Week \(Calendar.current.component(.weekOfYear, from: model.date)) \u{00B7} "
                + days.first!.lowerBound.formatted(.dateTime.day().month(.abbreviated)) + " \u{2013} "
                + days.last!.lowerBound.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var setupNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark").foregroundStyle(.secondary)
            Text(tracker.settings.enabled ? "Activity tracking needs Accessibility access to read window titles."
                 : "Activity tracking is off. Everything it records stays on this Mac.")
                .foregroundStyle(.secondary)
            Spacer()
            if tracker.settings.enabled {
                Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
            } else {
                Button("Turn On") { tracker.setEnabled(true) }
            }
        }
        .font(.callout)
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }
}

struct DayView: View {
    @ObservedObject var model: ActivityModel
    /// Blocks shorter than this are left out of the timeline (they still count in the totals).
    static let minimumShown: TimeInterval = 30

    var body: some View {
        let totals = ActivityLogic.projectTotals(model.blocks, in: model.day, rules: model.rules, projects: model.projects)
        let apps = ActivityLogic.appTotals(model.blocks, in: model.day)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ActivityLogic.hoursText(ActivityLogic.activeSeconds(model.blocks, in: model.day))).font(.system(size: 28, weight: .medium))
                    Text("active").foregroundStyle(.secondary)
                }
                if !totals.isEmpty {
                    FlowChips(totals.map { total in
                        Chip(text: "\(total.name) \u{00B7} \(ActivityLogic.hoursText(total.seconds))",
                             color: model.projects.first { $0.name == total.name }.map { Color(hex: $0.color) })
                    })
                }
                let categories = ActivityLogic.categoryTotals(model.blocks, in: model.day)
                if !categories.isEmpty {
                    FlowChips(categories.map { Chip(text: "\($0.name) \u{00B7} \(ActivityLogic.hoursText($0.seconds))", icon: "sparkles") })
                }
                if !apps.isEmpty {
                    Text(apps.prefix(8).map { "\($0.name) \(ActivityLogic.hoursText($0.seconds))" }.joined(separator: " \u{00B7} "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.blocks.isEmpty {
                Text(model.isToday ? "Nothing tracked yet today." : "Nothing tracked this day.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.blocks.filter { $0.duration >= Self.minimumShown }) { block in
                        BlockRow(block: block, model: model)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard let block = model.blocks.first(where: { $0.id == model.selected }) else { return .ignored }
                    model.delete(block)
                    model.selected = nil
                    return .handled
                }
            }
        }
    }
}

struct BlockRow: View {
    let block: ActivityBlock
    @ObservedObject var model: ActivityModel
    @State private var showingProject = false

    var body: some View {
        row
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(showingProject || model.selected == block.id ? 0.06 : 0)))
            .contentShape(Rectangle())
            .contextMenu { BlockMenu(block: block, model: model) }
    }

    @ViewBuilder private var row: some View {
        if block.key.idle || model.isPrivate(block) {
            HStack(spacing: 10) {
                timeColumn
                if block.key.idle {
                    Image(systemName: "moon.zzz").frame(width: 20)
                    Text("Away \u{00B7} \(ActivityLogic.hoursText(block.duration))")
                } else {
                    Image(systemName: "eye.slash").frame(width: 20)
                    Text("Private \u{00B7} \(block.category?.label ?? "")")
                    if let app = block.key.appName { Text(app) }
                    Spacer(minLength: 8)
                    Text(ActivityLogic.hoursText(block.duration)).monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onTapGesture { model.selected = block.id }
        } else {
            Button {
                model.selected = block.id
                showingProject = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    timeColumn.padding(.top, 1)
                    if let icon = model.icon(for: block) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(block.title ?? "Unknown").lineLimit(1)
                            if block.title != block.key.appName, let app = block.key.appName {
                                Text(app).foregroundStyle(.secondary)
                            }
                            if let description = block.aiDescription {
                                Label(description, systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .help("Described by Apple Intelligence")
                            }
                        }
                        let chips = chips
                        if !chips.isEmpty { FlowChips(chips) }
                        if let excerpt = block.claudePrompt ?? block.typedExcerpt {
                            Text("\u{201C}\(excerpt)\u{201D}")
                                .font(.caption)
                                .italic()
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(ActivityLogic.hoursText(block.duration)).foregroundStyle(.secondary).monospacedDigit()
                        if let project = model.project(of: block) {
                            HStack(spacing: 4) {
                                if ActivityLogic.projectIsGuessed(block, rules: model.rules) {
                                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                                Circle().fill(Color(hex: project.color)).frame(width: 7, height: 7)
                                Text(project.name).foregroundStyle(.secondary)
                            }
                            .help(ActivityLogic.projectIsGuessed(block, rules: model.rules) ? "Guessed by Apple Intelligence; click to accept or change" : "")
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingProject, arrowEdge: .trailing) { ProjectPicker(block: block, model: model) }
        }
    }

    private var timeColumn: some View {
        Text(block.start.formatted(date: .omitted, time: .shortened))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        if let url = block.key.url { chips.append(Chip(text: url, icon: "globe")) }
        if let repo = block.key.repo { chips.append(Chip(text: [repo, block.key.branch].compactMap { $0 }.joined(separator: " \u{00B7} "), icon: "arrow.triangle.branch")) }
        if let ticket = block.key.ticket { chips.append(Chip(text: ticket, icon: "tag")) }
        if let category = block.category { chips.append(Chip(text: category.label, icon: "square.grid.2x2")) }
        let lane = block.backgroundSessions
        if !lane.isEmpty {
            chips.append(Chip(text: lane.count == 1 ? lane[0].title : "\(lane.count) Claude sessions working", icon: "sparkles", tint: .purple,
                              help: lane.map(\.title).joined(separator: "\n")))
        }
        return chips
    }
}

/// The delete actions of a block, in its context menu.
struct BlockMenu: View {
    let block: ActivityBlock
    let model: ActivityModel

    var body: some View {
        Button("Delete") { model.delete(block) }
        if !block.key.idle, let app = block.key.appName {
            Button("Delete and Stop Tracking \(app)") { model.deleteAndStopTracking(block) }
        }
        if let host = block.host {
            Button("Delete All from \(host) \(Calendar.current.isDateInToday(block.start) ? "Today" : "This Day")") { model.deleteHost(of: block) }
        }
    }
}

/// Picks the project of a block, with a rule for everything like it and a field for a new project.
struct ProjectPicker: View {
    let block: ActivityBlock
    @ObservedObject var model: ActivityModel
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(block.title ?? "Block").font(.headline).lineLimit(2)
            Picker("Project", selection: Binding(get: { block.projectID ?? 0 }, set: { model.setProject($0 == 0 ? nil : $0, of: block) })) {
                Text(automaticLabel).tag(Int64(0))
                ForEach(model.projects) { Text($0.name).tag($0.id) }
            }
            if ActivityLogic.projectIsGuessed(block, rules: model.rules), let guess = model.projects.first(where: { $0.id == block.aiProjectID }) {
                Button { model.setProject(guess.id, of: block) } label: { Label("Accept suggestion: \(guess.name)", systemImage: "sparkles") }
            }
            if let project = chosenProject, let rule = ruleCandidate {
                Button("Always map \(rule.field.label.lowercased()) \u{201C}\(rule.pattern)\u{201D} to \(project.name)") {
                    model.addRule(rule.field, pattern: rule.pattern, project: project.id)
                    model.setProject(nil, of: block)
                }
                .disabled(model.rules.contains { $0.field == rule.field && $0.pattern.caseInsensitiveCompare(rule.pattern) == .orderedSame })
            }
            HStack {
                TextField("New project", text: $newName).textFieldStyle(.roundedBorder).onSubmit(create)
                Button("Create", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            Button(role: .destructive) { model.delete(block) } label: { Label("Delete", systemImage: "trash") }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var automaticLabel: String {
        let auto = ActivityLogic.project(for: ActivityBlock(id: block.id, start: block.start, end: block.end, key: block.key, projectID: nil),
                                         rules: model.rules, projects: model.projects)
        return auto.map { "Automatic (\($0.name))" } ?? "No project"
    }

    private var chosenProject: Project? {
        model.projects.first { $0.id == (block.projectID ?? model.project(of: block)?.id) }
    }

    private var ruleCandidate: (field: RuleField, pattern: String)? {
        if let repo = block.key.repo { return (.repo, repo) }
        if let host = block.host { return (.host, host) }
        if let ticket = block.key.ticket, let dash = ticket.firstIndex(of: "-") { return (.ticket, String(ticket[..<dash])) }
        return block.key.appName.map { (.app, $0) }
    }

    private func create() {
        guard let project = model.addProject(newName) else { return }
        model.setProject(project.id, of: block)
        newName = ""
    }
}

/// The time report: hours per project and day of the week.
struct WeekView: View {
    @ObservedObject var model: ActivityModel

    var body: some View {
        let days = model.week
        let totals = days.map { ActivityLogic.projectTotals(model.blocks, in: $0, rules: model.rules, projects: model.projects) }
        let names = totals.flatMap { $0.map(\.name) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let ordered = names.sorted { a, b in
            if (a == ActivityLogic.unassigned) != (b == ActivityLogic.unassigned) { return b == ActivityLogic.unassigned }
            return weekSeconds(a, totals) > weekSeconds(b, totals)
        }
        let categories = days.map { ActivityLogic.categoryTotals(model.blocks, in: $0) }
        let categoryNames = categories.flatMap { $0.map(\.name) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { weekSeconds($0, categories) > weekSeconds($1, categories) }
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ActivityLogic.hoursText(ActivityLogic.activeSeconds(model.blocks, in: model.range))).font(.system(size: 28, weight: .medium))
                Text("this week").foregroundStyle(.secondary)
            }
            if ordered.isEmpty {
                Text("Nothing tracked this week.").foregroundStyle(.secondary)
            } else {
                table("Project", days: days, names: ordered, totals: totals, withTotal: true) { name in
                    model.projects.first { $0.name == name }.map { Color(hex: $0.color) } ?? .secondary.opacity(0.4)
                }
                if !categoryNames.isEmpty {
                    table("Category", days: days, names: categoryNames, totals: categories, withTotal: false) { _ in nil }
                }
                HStack {
                    Button("Export CSV\u{2026}") { model.exportWeek(markdown: false) }
                    Button("Export Markdown\u{2026}") { model.exportWeek(markdown: true) }
                }
            }
        }
    }

    private func table(_ title: String, days: [Range<Date>], names: [String], totals: [[ActivityLogic.Total]], withTotal: Bool,
                       color: @escaping (String) -> Color?) -> some View {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text(title).gridColumnAlignment(.leading)
                        ForEach(days, id: \.lowerBound) { day in
                            Text(day.lowerBound.formatted(.dateTime.weekday(.abbreviated)))
                                .foregroundStyle(Calendar.current.isDateInToday(day.lowerBound) ? .primary : .secondary)
                        }
                        Text("Total")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(names, id: \.self) { name in
                        GridRow {
                            HStack(spacing: 6) {
                                if let color = color(name) { Circle().fill(color).frame(width: 8, height: 8) }
                                Text(name)
                            }
                            .gridColumnAlignment(.leading)
                            ForEach(Array(totals.enumerated()), id: \.offset) { _, dayTotals in
                                cell(dayTotals.first { $0.name == name }?.seconds ?? 0)
                            }
                            cell(weekSeconds(name, totals)).fontWeight(.medium)
                        }
                    }
                    if withTotal {
                        Divider()
                        GridRow {
                            Text("Total").gridColumnAlignment(.leading).fontWeight(.medium)
                            ForEach(days, id: \.lowerBound) { day in
                                cell(ActivityLogic.activeSeconds(model.blocks, in: day)).fontWeight(.medium)
                            }
                            cell(ActivityLogic.activeSeconds(model.blocks, in: model.range)).fontWeight(.medium)
                        }
                    }
                }
                .font(.callout)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func weekSeconds(_ name: String, _ totals: [[ActivityLogic.Total]]) -> TimeInterval {
        totals.reduce(0) { $0 + ($1.first { $0.name == name }?.seconds ?? 0) }
    }

    private func cell(_ seconds: TimeInterval) -> some View {
        Text(seconds > 0 ? ActivityLogic.hours(seconds) : "\u{2013}")
            .monospacedDigit()
            .foregroundStyle(seconds > 0 ? .primary : .tertiary)
    }
}

struct Chip: Hashable {
    let text: String
    var icon: String?
    var color: Color?
    var tint: Color?
    var help: String?
}

/// Small labels that wrap onto new lines.
struct FlowChips: View {
    let chips: [Chip]

    init(_ chips: [Chip]) { self.chips = chips }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                HStack(spacing: 4) {
                    if let color = chip.color { Circle().fill(color).frame(width: 7, height: 7) }
                    if let icon = chip.icon { Image(systemName: icon).font(.system(size: 9)) }
                    Text(chip.text).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(chip.tint ?? .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill((chip.tint ?? Color.primary).opacity(0.07)))
                .help(chip.help ?? "")
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(bounds.width, subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
