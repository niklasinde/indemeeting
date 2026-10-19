import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired { MainTabs() } else { WelcomeView() }
        }
        .sheet(item: $model.incomingPairing) { pairing in
            PairingConfirmView(pairing: pairing)
        }
        .fullScreenCover(isPresented: Binding(get: { model.needsRepair && model.isPaired }, set: { _ in })) {
            RepairView()
        }
        .task(id: model.isPaired) {
            guard model.isPaired else { return }
            model.loadCachedStatus()
            await model.refreshStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isPaired { Task { await model.refreshStatus() } }
        }
    }
}

extension PhonePairing: Identifiable {}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            MeetingsView().modifier(PlayerAccessoryInset()).tabItem { Label("Meetings", systemImage: "waveform") }.tag(AppTab.meetings)
            ActivityView().modifier(PlayerAccessoryInset()).tabItem { Label("Activity", systemImage: "chart.bar.xaxis") }.tag(AppTab.activity)
            GitHubView().modifier(PlayerAccessoryInset()).tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }.tag(AppTab.github)
            ChatTab().modifier(PlayerAccessoryInset()).tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(AppTab.chat)
            SettingsView().modifier(PlayerAccessoryInset()).tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .modifier(PlayerAccessory(active: model.player.track != nil))
        .minimizesTabBarOnScroll()
    }
}

/// The mini player above the tab bar. From iOS 26.1 it is the tab view's bottom accessory; before that it is an inset in each tab.
private struct PlayerAccessory: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) { content.tabViewBottomAccessory(isEnabled: active) { MiniPlayer() } } else { content }
    }
}

private struct PlayerAccessoryInset: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if model.player.track != nil { MiniPlayer().padding(.vertical, 10).glassBackground(Capsule()).padding(.horizontal).padding(.bottom, 4) }
            }
        }
    }
}
