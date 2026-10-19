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
            MeetingsView().tabItem { Label("Meetings", systemImage: "waveform") }.tag(AppTab.meetings)
            ActivityView().tabItem { Label("Activity", systemImage: "chart.bar.xaxis") }.tag(AppTab.activity)
            GitHubView().tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }.tag(AppTab.github)
            ChatTab().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(AppTab.chat)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .modifier(PlayerAccessory(active: model.player.track != nil))
        .minimizesTabBarOnScroll()
    }
}

/// The mini player above the tab bar; before iOS 26.1 the accessory cannot be switched off, so it is a bottom inset there.
private struct PlayerAccessory: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: active) { MiniPlayer() }
        } else {
            content.safeAreaInset(edge: .bottom) {
                if active { MiniPlayer().padding(.vertical, 10).glassBackground(Capsule()).padding(.horizontal).padding(.bottom, 56) }
            }
        }
    }
}
