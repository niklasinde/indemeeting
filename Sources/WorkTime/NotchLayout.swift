import CoreGraphics

/// Where the notch bar sits on a screen. The notch is found from the widths of the areas beside it, so it does not matter
/// whether AppKit reports those areas in the screen's own or in global coordinates.
enum NotchLayout {
    static func notch(screen: CGRect, left: CGRect?, right: CGRect?) -> (centre: CGFloat, width: CGFloat?) {
        guard let left, let right else { return (screen.midX, nil) }
        let start = screen.minX + left.width
        let end = screen.maxX - right.width
        guard end > start else { return (screen.midX, nil) }
        return ((start + end) / 2, end - start)
    }

    /// The panel hangs from the top of the screen, centred on the notch.
    static func panelFrame(screen: CGRect, left: CGRect?, right: CGRect?, size: CGSize) -> CGRect {
        let centre = notch(screen: screen, left: left, right: right).centre
        return CGRect(x: centre - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
}
