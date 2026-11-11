import CoreGraphics
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func builtIn(width: CGFloat, height: CGFloat, notch: CGFloat, at origin: CGPoint = .zero, globalAreas: Bool = false)
    -> (screen: CGRect, left: CGRect, right: CGRect) {
    let screen = CGRect(origin: origin, size: CGSize(width: width, height: height))
    let wing = (width - notch) / 2
    let shift = globalAreas ? origin : .zero
    let left = CGRect(x: shift.x, y: shift.y + height - 32, width: wing, height: 32)
    let right = CGRect(x: shift.x + wing + notch, y: shift.y + height - 32, width: wing, height: 32)
    return (screen, left, right)
}

let notchLayoutTests: [(name: String, run: () throws -> Void)] = [
    ("the bar is centred on the notch of a 1512 and a 1728 point built-in display", {
        for (width, height) in [(1512.0, 982.0), (1728.0, 1117.0)] {
            let display = builtIn(width: width, height: height, notch: 188)
            let notch = NotchLayout.notch(screen: display.screen, left: display.left, right: display.right)
            check(notch.centre == width / 2, "centre at \(width)")
            check(notch.width == 188, "notch width at \(width)")
            let frame = NotchLayout.panelFrame(screen: display.screen, left: display.left, right: display.right,
                                               size: CGSize(width: 256, height: 32))
            check(frame == CGRect(x: width / 2 - 128, y: height - 32, width: 256, height: 32), "frame at \(width): \(frame)")
        }
    }),

    ("the bar stays on the notch whatever width the content has when the panel is placed", {
        let display = builtIn(width: 1800, height: 1169, notch: 220)
        for width in [68.0, 288, 588] {
            let frame = NotchLayout.panelFrame(screen: display.screen, left: display.left, right: display.right,
                                               size: CGSize(width: width, height: 38))
            check(frame.midX == 900, "a \(width) wide panel is centred on the notch: \(frame)")
            check(frame.maxY == 1169, "it hangs from the top of the screen")
        }
    }),

    ("a built-in display beside or below another screen keeps the bar on its notch, in local or global area coordinates", {
        for origin in [CGPoint(x: -1512, y: 300), CGPoint(x: 2560, y: 0), CGPoint(x: 400, y: -982)] {
            for global in [false, true] {
                let display = builtIn(width: 1512, height: 982, notch: 188, at: origin, globalAreas: global)
                let frame = NotchLayout.panelFrame(screen: display.screen, left: display.left, right: display.right,
                                                   size: CGSize(width: 256, height: 32))
                check(frame == CGRect(x: origin.x + 628, y: origin.y + 950, width: 256, height: 32),
                      "origin \(origin), global areas \(global): \(frame)")
            }
        }
    }),

    ("a list scrolls once it would run past the bottom of the screen, and never gets shorter than the minimum", {
        check(NotchLayout.listCap(visibleHeight: 944) == 684, "a 1512 x 982 display under its menu bar")
        check(NotchLayout.listCap(visibleHeight: 1079) == 819, "a 1728 x 1117 display")
        check(NotchLayout.listCap(visibleHeight: 300) == NotchLayout.minimumListHeight, "a very short screen")
    }),

    ("a screen without a notch centres the bar on the screen", {
        let screen = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        let notch = NotchLayout.notch(screen: screen, left: nil, right: nil)
        check(notch.centre == -1280, "centre")
        check(notch.width == nil, "no notch")
        let frame = NotchLayout.panelFrame(screen: screen, left: nil, right: nil, size: CGSize(width: 268, height: 24))
        check(frame == CGRect(x: -1414, y: 1216, width: 268, height: 24), "frame \(frame)")
        let overlapping = NotchLayout.notch(screen: screen, left: CGRect(x: 0, y: 0, width: 1400, height: 24),
                                            right: CGRect(x: 0, y: 0, width: 1400, height: 24))
        check(overlapping.width == nil && overlapping.centre == -1280, "areas that leave no gap are not a notch")
    }),
]
