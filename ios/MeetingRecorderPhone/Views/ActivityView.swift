import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: ActivityModel?
    @State private var asking = false

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .navigationTitle("Activity")
        }
        .task {
            let model = model ?? ActivityModel(model: appModel)
            self.model = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: ActivityModel) -> some View {
        let resource = model.resource
        List {
            Section {
                Picker("Range", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                    ForEach(ActivityModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section { DateStepper(model: model) }
            SyncBanner(error: resource.error, syncedAt: resource.syncedAt) { Task { await model.load() } }
                .listRowBackground(Color.orange.opacity(0.12))
            if let activity = resource.value {
                ActivitySections(activity: activity, model: model)
            }
        }
        .overlay {
            if resource.value == nil {
                if resource.isLoading { ProgressView() }
                else if let error = resource.error { ProblemView(title: error.problemTitle, message: error.hint, actionTitle: "Try again") { Task { await model.load() } } }
            }
        }
        .refreshable { await model.load() }
        .task(id: model.key) { await model.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { asking = true } label: { Label("Ask about this \(model.mode == .day ? "day" : "week")", systemImage: "bubble.left.and.text.bubble.right") }
            }
        }
        .sheet(isPresented: $asking) {
            ChatSheet(scope: PhoneChatScope(kind: model.mode == .day ? "day" : "week", date: PhoneFormat.dayString(model.date)), title: model.title)
        }
    }
}

private struct DateStepper: View {
    let model: ActivityModel

    var body: some View {
        HStack {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(model.mode == .day ? "Previous day" : "Previous week")
            Spacer()
            Button { model.goToToday() } label: {
                VStack(spacing: 0) {
                    Text(model.title).font(.headline)
                    if !model.isCurrent { Text("Go to today").font(.caption).foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canStepForward)
                .accessibilityLabel(model.mode == .day ? "Next day" : "Next week")
        }
        .buttonStyle(.borderless)
    }
}

private struct ActivitySections: View {
    @Environment(\.openURL) private var openURL
    let activity: PhoneActivity
    let model: ActivityModel

    var body: some View {
        let totals = activity.totals
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(PhoneFormat.duration(totals.activeSeconds)).font(.system(.largeTitle, design: .rounded).bold())
                Text("active").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if model.mode == .week {
                let peak = activity.days.map(\.activeSeconds).max() ?? 0
                ForEach(activity.days, id: \.date) { day in
                    Button { model.select(day: day.date) } label: {
                        HStack(spacing: 10) {
                            Text(PhoneFormat.day(from: day.date).map { $0.formatted(.dateTime.weekday(.abbreviated)) } ?? day.date)
                                .font(.subheadline).frame(width: 40, alignment: .leading)
                            ShareBar(fraction: PhoneFormat.percent(day.activeSeconds, of: peak))
                            Text(day.activeSeconds > 0 ? PhoneFormat.duration(day.activeSeconds) : "\u{2013}")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this day")
                }
            }
        }
        if totals.activeSeconds == 0 && activity.blocks.isEmpty {
            Section { ProblemView(title: "No activity", message: "Nothing was tracked in this range.", systemImage: "moon.zzz").listRowBackground(Color.clear) }
        }
        totalsSection("Projects", totals.projects, total: totals.activeSeconds)
        totalsSection("Categories", totals.categories, total: totals.activeSeconds)
        if !totals.branches.isEmpty {
            Section("Branches") {
                ForEach(Array(totals.branches.enumerated()), id: \.offset) { _, branch in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(branch.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(PhoneFormat.duration(branch.seconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        FlowLayout(spacing: 4) {
                            if let repo = branch.repo { Chip(text: repo, systemImage: "shippingbox") }
                            if let ticket = branch.ticket { Chip(text: ticket, systemImage: "ticket", tint: .blue) }
                            if let project = branch.project { projectChip(project, guessed: branch.projectGuessed) }
                        }
                        ShareBar(fraction: PhoneFormat.percent(branch.seconds, of: totals.activeSeconds))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if !totals.tickets.isEmpty {
            Section("Tickets") {
                ForEach(totals.tickets, id: \.ticket) { ticket in
                    Button { ticket.url.flatMap(URL.init(string:)).map { openURL($0) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(ticket.ticket).font(.subheadline.weight(.semibold)).foregroundStyle(ticket.url == nil ? Color.primary : .blue)
                                if ticket.url != nil { Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(.blue) }
                                Spacer()
                                Text(PhoneFormat.duration(ticket.seconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if let title = ticket.title { Text(title).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                            if let project = ticket.project { projectChip(project, guessed: ticket.projectGuessed) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(ticket.url == nil ? "" : "Opens the ticket in Safari")
                }
            }
        }
        totalsSection("Apps", totals.apps, total: totals.activeSeconds)
        if model.mode == .day, !activity.blocks.isEmpty {
            Section("Timeline") {
                ForEach(activity.blocks, id: \.id) { BlockRow(block: $0) }
            }
        }
    }

    @ViewBuilder
    private func totalsSection(_ title: String, _ items: [PhoneTotal], total: Double) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.name).font(.subheadline)
                            Spacer()
                            Text(PhoneFormat.duration(item.seconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ShareBar(fraction: PhoneFormat.percent(item.seconds, of: total), tint: Color.tint(for: item.name))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

func projectChip(_ project: String, guessed: Bool) -> some View {
    Chip(text: project, systemImage: guessed ? "sparkle" : "folder", tint: Color.tint(for: project))
        .accessibilityLabel(guessed ? "Project \(project), guessed" : "Project \(project)")
}

private struct BlockRow: View {
    @Environment(\.openURL) private var openURL
    let block: PhoneBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(block.start.timeText) \u{2013} \(block.end.timeText)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("\u{00B7} " + PhoneFormat.duration(block.end.timeIntervalSince(block.start))).font(.caption).foregroundStyle(.secondary)
            }
            if let redaction = block.redaction {
                Label(redaction == "other" ? "Hidden by tracking rules" : "\(block.app ?? "Private")", systemImage: "lock.fill").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(block.summary ?? block.title ?? block.app ?? "Activity").font(.subheadline.weight(.medium)).lineLimit(3)
            }
            if let excerpt = block.excerpt, !excerpt.isEmpty { Text(excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            FlowLayout(spacing: 4) {
                if let app = block.app, block.redaction == nil { Chip(text: app, systemImage: "app") }
                if let category = block.category { Chip(text: category) }
                if let repo = block.repo { Chip(text: repo, systemImage: "shippingbox") }
                if let branch = block.branch { Chip(text: branch, systemImage: "arrow.triangle.branch") }
                if let ticket = block.ticket { Chip(text: ticket, systemImage: "ticket", tint: .blue) }
                if let project = block.project { projectChip(project, guessed: block.projectGuessed) }
            }
            .lineLimit(1)
            if let url = block.url.flatMap(URL.init(string:)), block.redaction == nil, ["http", "https"].contains(url.scheme) {
                Button { openURL(url) } label: { Label(url.host() ?? url.absoluteString, systemImage: "safari").font(.caption) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
