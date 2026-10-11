import AppKit

/// Reads and replaces the text you've selected in any app, going through the clipboard and restoring
/// whatever was on it before.
@MainActor
enum TextTools {
    enum Operation: Equatable {
        case summarize, explain, read, translate(String), rewrite(String), fixGrammar, reply

        /// Whether the result replaces the selection (vs. being shown and spoken).
        var replaces: Bool {
            switch self { case .rewrite, .fixGrammar: return true; default: return false }
        }

        var instruction: String {
            switch self {
            case .summarize: return "Summarize this in two or three short sentences."
            case .explain: return "Explain this simply in two or three sentences."
            case .read: return ""
            case .translate(let lang): return "Translate this into \(lang). Reply with only the translation."
            case .rewrite(let style): return "Rewrite this to be \(style). Keep the meaning. Reply with only the rewritten text."
            case .fixGrammar: return "Fix the spelling and grammar. Keep the wording otherwise. Reply with only the corrected text."
            case .reply: return "Write a short, friendly reply to this message. Reply with only the reply text."
            }
        }

        var label: String {
            switch self {
            case .summarize: return "Summarize"
            case .explain: return "Explain"
            case .read: return "Read aloud"
            case .translate(let l): return "Translate to \(l)"
            case .rewrite(let s): return "Make it \(s)"
            case .fixGrammar: return "Fix grammar"
            case .reply: return "Draft a reply"
            }
        }
    }

    /// The current selection, or nil if nothing is selected.
    static func selectedText() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        Keyboard.press(Key.Combo(key: Key.code["c"]!, mods: .cmd))
        for _ in 0..<12 where pb.changeCount == before { try? await Task.sleep(for: .milliseconds(40)) }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        restore(pb, saved)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The whole page or document in the front window (select all + copy).
    static func pageText() async -> String? {
        Keyboard.press(Key.Combo(key: Key.code["escape"]!, mods: []))
        Keyboard.press(Key.Combo(key: Key.code["a"]!, mods: .cmd))
        try? await Task.sleep(for: .milliseconds(80))
        let text = await selectedText()
        // Collapse the selection again.
        Keyboard.press(Key.Combo(key: Key.code["right"]!, mods: []))
        return text
    }

    /// Replaces the selection by pasting, then restores the clipboard.
    static func replaceSelection(with text: String) async {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        Keyboard.press(Key.Combo(key: Key.code["v"]!, mods: .cmd))
        try? await Task.sleep(for: .milliseconds(250))
        restore(pb, saved)
    }

    static func clipboard() -> String? { NSPasteboard.general.string(forType: .string)?.nilIfEmpty }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        })
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
