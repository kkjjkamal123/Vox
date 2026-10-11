import AppKit
import CoreGraphics

enum Key {
    struct Mods: OptionSet {
        let rawValue: Int
        static let cmd = Mods(rawValue: 1), shift = Mods(rawValue: 2), opt = Mods(rawValue: 4), ctrl = Mods(rawValue: 8), fn = Mods(rawValue: 16)
        var flags: CGEventFlags {
            var f: CGEventFlags = []
            if contains(.cmd) { f.insert(.maskCommand) }
            if contains(.shift) { f.insert(.maskShift) }
            if contains(.opt) { f.insert(.maskAlternate) }
            if contains(.ctrl) { f.insert(.maskControl) }
            if contains(.fn) { f.insert(.maskSecondaryFn) }
            return f
        }
    }
    struct Combo { let key: CGKeyCode; let mods: Mods }

    /// ANSI virtual key codes.
    static let code: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let spokenKeys: [String: String] = [
        "enter": "return", "return": "return", "escape": "escape", "esc": "escape", "tab": "tab", "space": "space",
        "spacebar": "space", "delete": "delete", "backspace": "delete", "up": "up", "down": "down", "left": "left",
        "right": "right", "home": "home", "end": "end", "comma": ",", "period": ".", "dot": ".", "slash": "/",
        "minus": "-", "equals": "=",
    ]
    private static let spokenMods: [String: Mods] = [
        "command": .cmd, "cmd": .cmd, "shift": .shift, "option": .opt, "alt": .opt, "control": .ctrl, "ctrl": .ctrl,
    ]

    /// "command shift t", "enter", "control tab"
    static func parseCombo(_ words: [String]) -> Combo? {
        var mods: Mods = []
        var key: CGKeyCode?
        for w in words where !["plus", "and", "arrow", "key", "the"].contains(w) {
            if let m = spokenMods[w] { mods.insert(m) }
            else if let k = spokenKeys[w].flatMap({ code[$0] }) ?? code[w] { key = k }
            else { return nil }
        }
        return key.map { Combo(key: $0, mods: mods) }
    }
}

/// Synthesized keyboard input. Posting events requires the Accessibility permission.
enum Keyboard {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func press(_ c: Key.Combo) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: c.key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: c.key, keyDown: false)
        down?.flags = c.mods.flags
        up?.flags = c.mods.flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Types arbitrary Unicode text independent of keyboard layout.
    static func type(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { press(Key.Combo(key: Key.code["return"]!, mods: .shift)) }
            let utf16 = Array(line.element.utf16)
            var i = 0
            while i < utf16.count {
                let chunk = Array(utf16[i..<min(i + 20, utf16.count)])   // CGEvent carries at most 20 UTF-16 units
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                i += 20
            }
        }
    }

    static func backspace(_ n: Int) {
        for _ in 0..<n { press(Key.Combo(key: Key.code["delete"]!, mods: [])) }
    }

    /// Hardware media keys (volume, brightness, play/pause) via NX system-defined events.
    static func media(_ nxKey: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((nxKey << 16) | (down ? 0xA00 : 0xB00))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
