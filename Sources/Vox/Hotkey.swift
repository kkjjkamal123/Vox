import Carbon

/// System-wide hotkey through Carbon, which needs no extra permission and costs nothing while idle
/// (no event tap, no key monitoring). Reports both press and release so it can do push-to-talk.
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handlers: (down: () -> Void, up: () -> Void)?
    /// False if another app already owns the shortcut (macOS then never delivers it to Vox).
    private(set) var registered = false

    init(keyCode: Int = kVK_Space, modifiers: Int = optionKey, down: @escaping () -> Void, up: @escaping () -> Void) {
        Hotkey.handlers = (down, up)
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            // Carbon delivers application-target events on the main thread.
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { if pressed { Hotkey.handlers?.down() } else { Hotkey.handlers?.up() } }
            return noErr
        }, 2, &types, nil, nil)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x564F5821), id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        if !registered { NSLog("Vox: couldn't register the ⌥Space hotkey (error \(status)); another app may be using it") }
    }
}
