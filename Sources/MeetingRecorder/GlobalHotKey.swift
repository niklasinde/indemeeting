import Carbon
import SwiftUI

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility permission. It stays
/// registered for the life of the app.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥⌘R starts and stops recording.
    static let record = (key: KeyEquivalent("r"), modifiers: EventModifiers([.control, .option, .command]),
                         keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))

    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4D52_4543), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
