import Carbon

/// System-wide hotkey through Carbon, which needs no extra permission and costs nothing while idle
/// (no event tap, no key monitoring). Reports both press and release so it can do push-to-talk.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handlers: (down: () -> Void, up: () -> Void)?

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey, down: @escaping () -> Void, up: @escaping () -> Void) {
        Hotkey.handlers = (down, up)
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { Hotkey.handlers?.down() } else { Hotkey.handlers?.up() }
            return noErr
        }, 2, &types, nil, nil)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x564F5821), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
