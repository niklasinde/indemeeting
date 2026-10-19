import SwiftUI

/// The iOS 26 glass look where it exists, and a material or the plain style before it, so the app also runs on the
/// older simulators this project can be tested on.
extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) { glassEffect(.regular, in: shape) } else { background(.regularMaterial, in: shape) }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    @ViewBuilder
    func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
}
