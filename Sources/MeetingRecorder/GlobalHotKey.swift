import Carbon
import SwiftUI

/// A system-wide shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility permission. It stays
/// registered until `unregister()`.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥⌘R starts and stops recording.
    static let record = (key: KeyEquivalent("r"), modifiers: EventModifiers([.control, .option, .command]),
                         keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
    private static var nextID: UInt32 = 1

    private let action: () -> Void
    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4D52_4543), id: id),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
