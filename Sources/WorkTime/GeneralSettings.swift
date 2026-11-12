import AppKit
import SwiftUI

extension AppAppearance {
    @MainActor
    func apply() {
        NSApp.appearance = isDark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
    }
}

/// The options that belong to the whole app rather than to one feature.
struct GeneralSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @AppStorage(SidebarLogic.hiddenKey) private var sidebarHidden = false
    @AppStorage(SidebarLogic.showChatKey) private var showChat = true
    @AppStorage(AudioRetention.developerModeKey) private var developerMode = false
    @ObservedObject private var upgrade = AppUpgrade.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Appearance", footer: "System follows the Mac\u{2019}s light or dark mode. The notch bar stays dark "
                            + "so it blends with the notch.") {
                SettingsRow("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsSection("Main window", footer: nil) {
                SettingsRow("Show sidebar", detail: SidebarLogic.sidebarDetail(showChat: showChat)) {
                    toggle("Show sidebar", isOn: Binding(get: { !sidebarHidden }, set: { sidebarHidden = !$0 }))
                }
                Divider().padding(.leading, 14)
                SettingsRow("Show Chat", detail: SidebarSection.chat.help) {
                    toggle("Show Chat", isOn: $showChat)
                }
            }
            SettingsSection("Developer", footer: "A new recording\u{2019}s audio is deleted from this Mac for good once its transcript "
                            + "and summary are saved. Recordings made in developer mode keep their audio, also after it is turned off.") {
                SettingsRow("Developer mode", detail: "Keep the audio of new recordings") {
                    toggle("Developer mode", isOn: $developerMode)
                }
            }
            SettingsSection("About", footer: nil) {
                SettingsRow("WorkTime", detail: UpgradeLogic.versionLabel) {
                    if upgrade.ready { Button("Restart to upgrade") { upgrade.restartNow() } }
                }
                Divider().padding(.leading, 14)
                SettingsRow("Setup & Help", detail: Permissions.allGranted ? "Permissions and a tour of the app"
                                                                           : "Some permissions are missing") {
                    Button("Open\u{2026}") { OnboardingWindow.shared.show() }
                }
            }
        }
        .onChange(of: appearance) { appearance.apply() }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}
