import SwiftUI

enum AgentWorkMap {
    static let shownKey = "agentWorkMapShown"
    static let panelWidth: CGFloat = 340
    /// The pane width from which the map fits beside the transcript; narrower panes show it in a popover.
    static let sideMinWidth: CGFloat = 780
    static let popoverSize = CGSize(width: 360, height: 620)

    static let panel = tinted(.windowBackgroundColor, with: NSColor(red: 0.93, green: 0.84, blue: 0.68, alpha: 1), light: 0.42, dark: 0.10)
    static let node = tinted(.textBackgroundColor, with: NSColor(red: 0.95, green: 0.80, blue: 0.60, alpha: 1), light: 0, dark: 0.14)
    static let line = tinted(.labelColor, with: NSColor(red: 0.62, green: 0.42, blue: 0.22, alpha: 1), light: 0.5, dark: 0.3)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(red: 0.96, green: 0.60, blue: 0.38, alpha: 1) : NSColor(red: 0.80, green: 0.39, blue: 0.20, alpha: 1)
    })

    private static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// A system colour pulled towards a warm one, by a different amount in light and dark.
    private static func tinted(_ base: NSColor, with warm: NSColor, light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = base
            appearance.performAsCurrentDrawingAppearance {
                let resolved = base.usingColorSpace(.sRGB) ?? base
                result = resolved.blended(withFraction: isDark(appearance) ? dark : light, of: warm) ?? resolved
            }
            return result
        })
    }
}

/// Claude in the middle, the kinds of work around it, and what this session did newest first.
struct AgentWorkMapView: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let map = model.workMap
            VStack(spacing: 0) {
                WorkMapDiagram(map: map, now: timeline.date)
                    .frame(height: 318)
                Text(map.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                Divider().overlay(AgentWorkMap.line.opacity(0.2))
                log(map)
            }
            .background(AgentWorkMap.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
        }
    }

    @ViewBuilder
    private func log(_ map: WorkMap) -> some View {
        if map.isEmpty {
            Text("What the agent does shows up here as it works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(map.events.reversed()) { event in
                        WorkMapRow(event: event, text: map.text(event))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct WorkMapRow: View {
    let event: WorkMapEvent
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.category.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(event.running ? AnyShapeStyle(AgentWorkMap.accent) : AnyShapeStyle(.secondary))
                .frame(width: 54, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(event.running ? AnyShapeStyle(AgentWorkMap.accent) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Text(event.running ? "running" : event.durationText ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(event.running ? AnyShapeStyle(AgentWorkMap.accent) : AnyShapeStyle(.tertiary))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

private struct WorkMapDiagram: View {
    let map: WorkMap
    let now: Date

    private static let nodeSize: CGFloat = 38
    private static let centreSize: CGFloat = 88

    var body: some View {
        GeometryReader { proxy in
            let centre = CGPoint(x: proxy.size.width / 2, y: 142)
            let radius = min(proxy.size.width / 2 - 42, 118)
            let categories = WorkMapCategory.allCases
            ZStack {
                Canvas { context, _ in
                    for ring in [radius * 0.66, radius, radius * 1.3] {
                        let circle = Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2))
                        context.stroke(circle, with: .color(AgentWorkMap.line.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
                    }
                    for (index, category) in categories.enumerated() {
                        let warmth = map.warmth(category, at: now), active = map.active == category
                        var spoke = Path()
                        spoke.move(to: point(index: index, of: categories.count, centre: centre, radius: Self.centreSize / 2 + 8))
                        spoke.addLine(to: point(index: index, of: categories.count, centre: centre, radius: radius - Self.nodeSize / 2))
                        let colour = warmth > 0 ? AgentWorkMap.accent.opacity(0.35 + 0.65 * warmth) : AgentWorkMap.line.opacity(0.35)
                        context.stroke(spoke, with: .color(colour), lineWidth: active ? 2 : 0.75)
                    }
                }
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    WorkMapNode(category: category, count: map.counts[category] ?? 0, warmth: map.warmth(category, at: now),
                                active: map.active == category, size: Self.nodeSize)
                        .position(point(index: index, of: categories.count, centre: centre, radius: radius))
                }
                centreNode.position(centre)
            }
        }
        .clipped()
    }

    /// The nodes sit either side of the top, so the context percent above Claude stays clear.
    private func point(index: Int, of count: Int, centre: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (Double(index) + 0.5) / Double(count) * 2 * .pi - .pi / 2
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    private var centreNode: some View {
        let fraction = Double(map.contextPercent ?? 0) / 100
        return ZStack {
            Circle().fill(AgentWorkMap.node)
                .frame(width: Self.centreSize, height: Self.centreSize)
                .shadow(color: map.active == nil ? .black.opacity(0.08) : AgentWorkMap.accent.opacity(0.35), radius: map.active == nil ? 3 : 8)
            Circle().stroke(AgentWorkMap.line.opacity(0.18), lineWidth: 2.5)
                .frame(width: Self.centreSize + 10, height: Self.centreSize + 10)
            Circle().trim(from: 0, to: fraction)
                .stroke(AgentWorkMap.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.centreSize + 10, height: Self.centreSize + 10)
            VStack(spacing: 2) {
                Text("CLAUDE").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.5)
                Text(map.modelLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Self.centreSize - 10)
            if let context = map.contextText {
                Text(context)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentWorkMap.accent)
                    .fixedSize()
                    .offset(y: -(Self.centreSize / 2 + 18))
                    .help("How full the context window is")
            }
        }
    }
}

private struct WorkMapNode: View {
    let category: WorkMapCategory
    let count: Int
    let warmth: Double
    let active: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(AgentWorkMap.node)
                .shadow(color: active ? AgentWorkMap.accent.opacity(0.55) : .black.opacity(0.08), radius: active ? 7 : 2)
            Circle().fill(AgentWorkMap.accent.opacity(0.2 * warmth))
            Circle().stroke(active ? AgentWorkMap.accent : AgentWorkMap.line.opacity(0.25 + 0.4 * warmth), lineWidth: active ? 2 : 0.75)
            Image(systemName: category.symbol)
                .font(.system(size: 14))
                .foregroundStyle(warmth > 0 ? AnyShapeStyle(AgentWorkMap.accent) : AnyShapeStyle(.secondary))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Text(category.label).font(.system(size: 10, weight: active ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(active ? AnyShapeStyle(AgentWorkMap.accent) : AnyShapeStyle(.primary))
                if count > 0 { Text("\(count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
            }
            .fixedSize()
            .offset(y: size + 3)
        }
        .animation(.easeOut(duration: 0.3), value: active)
        .help(count == 1 ? "\(category.label): 1 event" : "\(category.label): \(count) events")
    }
}

/// Shows the map beside the transcript in a wide pane, in a popover from the button in a narrow one.
struct AgentWorkMapToggle: View {
    @ObservedObject var model: AgentModel
    let wide: Bool
    @AppStorage(AgentWorkMap.shownKey, store: AgentModel.defaults) private var shown = false
    @State private var popover = false

    var body: some View {
        Toggle(isOn: Binding(get: { wide ? shown : popover }, set: { if wide { shown = $0 } else { popover = $0 } })) {
            Label("Work map", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .toggleStyle(.button)
        .help("Work map")
        .popover(isPresented: $popover, arrowEdge: .bottom) {
            AgentWorkMapView(model: model).frame(width: AgentWorkMap.popoverSize.width, height: AgentWorkMap.popoverSize.height)
        }
        .onChange(of: wide) { if wide { popover = false } }
    }
}

struct AgentWorkMapSplit<Content: View>: View {
    @ObservedObject var model: AgentModel
    let wide: Bool
    @AppStorage(AgentWorkMap.shownKey, store: AgentModel.defaults) private var shown = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
            if wide && shown {
                Divider()
                AgentWorkMapView(model: model).frame(width: AgentWorkMap.panelWidth)
            }
        }
    }
}
