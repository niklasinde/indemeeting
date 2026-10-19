import SwiftUI

/// Renders Markdown inline, keeping line breaks and showing `- ` lines as bullets.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.attributed(text))
    }

    static func attributed(_ text: String) -> AttributedString {
        let bulleted = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ? "\u{2022} " + trimmed.dropFirst(2) : line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Shown above cached content when the Mac does not answer.
struct SyncBanner: View {
    @Environment(AppModel.self) private var model
    let error: PhoneNetworkError?
    let syncedAt: Date?
    var retry: () -> Void

    var body: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(error)).font(.subheadline.weight(.semibold))
                    if let syncedAt { Text("Last synced \(syncedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button("Retry", action: retry).buttonStyle(.bordered).controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Retry connecting to your Mac")
        }
    }

    private func title(_ error: PhoneNetworkError) -> String {
        switch error {
        case .unreachable, .timeout, .connectionLost: return "Showing saved data. Mac not reachable."
        case .blocked: return "The Mac is blocking this phone for a moment."
        default: return error.message
        }
    }
}

/// Full-screen state for a screen with nothing to show: Mac off, wrong network, feature off.
struct ProblemView: View {
    let title: String
    let message: String
    var systemImage = "wifi.exclamationmark"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent) }
        }
    }
}

extension PhoneNetworkError {
    var problemTitle: String {
        switch self {
        case .unreachable, .timeout, .connectionLost: return "Mac not reachable"
        case .blocked: return "Blocked for a moment"
        case .keyRejected: return "Not paired"
        default: return "Something went wrong"
        }
    }

    var hint: String {
        switch self {
        case .unreachable, .timeout, .connectionLost:
            return message + " If you just installed the app, allow Local Network access in Settings > Meeting Recorder."
        default: return message
        }
    }
}

/// A thin proportion bar behind a total, as the Mac view draws them.
struct ShareBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(tint.opacity(0.18))
                .overlay(alignment: .leading) { Capsule().fill(tint.gradient).frame(width: max(proxy.size.width * fraction, fraction > 0 ? 4 : 0)) }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// A stable colour per name, so a project or speaker keeps its colour.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .mint, .brown, .cyan]
        return palette[Int(name.unicodeScalars.reduce(UInt32(5381)) { $0 &* 33 &+ $1.value } % UInt32(palette.count))]
    }
}

extension Date {
    var timeText: String { formatted(date: .omitted, time: .shortened) }
}

/// Lays children out left to right and wraps to the next line, for rows of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(bounds.width, subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
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
