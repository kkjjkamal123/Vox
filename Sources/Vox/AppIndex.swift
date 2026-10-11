import Foundation

/// Installed applications, indexed once at launch so name lookups never touch the disk.
final class AppIndex: @unchecked Sendable {
    static let shared = AppIndex()

    struct App { let name: String; let url: URL }

    private(set) var apps: [String: App] = [:]   // normalized name -> app

    /// Spoken names that don't match the bundle name.
    private let aliases: [String: String] = [
        "settings": "system settings", "system preferences": "system settings", "preferences": "system settings",
        "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code",
        "code": "visual studio code", "word": "microsoft word", "excel": "microsoft excel",
        "powerpoint": "microsoft powerpoint", "outlook": "microsoft outlook", "teams": "microsoft teams",
        "apple music": "music", "itunes": "music", "files": "finder", "activity": "activity monitor",
        "task manager": "activity monitor", "calendar app": "calendar", "whatsapp": "whatsapp",
        "facetime": "facetime", "face time": "facetime", "app store": "app store", "appstore": "app store",
        "note": "notes", "the notes": "notes", "text edit": "textedit", "iterm": "iterm",
    ]

    private init() {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
                     "/System/Library/CoreServices"]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                let key = name.lowercased()
                if root == "/System/Library/CoreServices" && key != "finder" { continue }
                if key == "vox" { continue }   // ourselves: "hey vox" must never mean "open Vox"
                if apps[key] == nil { apps[key] = App(name: name, url: URL(fileURLWithPath: root).appendingPathComponent(item)) }
            }
        }
    }

    /// Names to bias the speech recognizer toward.
    var contextualNames: [String] { apps.values.map(\.name) }

    /// Exact (or alias) match only; used for eager, mid-sentence execution.
    func exact(_ spoken: String) -> App? {
        let s = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        if let a = apps[s] { return a }
        if let alias = aliases[s], let a = apps[alias] { return a }
        let compact = s.replacingOccurrences(of: " ", with: "")
        return apps.first { $0.key.replacingOccurrences(of: " ", with: "") == compact }?.value
    }

    /// Exact match, then prefix, then a one-edit fuzzy match to absorb recognition errors.
    func find(_ spoken: String) -> App? {
        if let a = exact(spoken) { return a }
        let s = spoken.lowercased()
        guard s.count >= 3 else { return nil }
        if let a = apps.filter({ $0.key.hasPrefix(s + " ") || $0.key.hasSuffix(" " + s) })
            .min(by: { $0.key.count < $1.key.count }) { return a.value }
        guard s.count >= 5 else { return nil }
        return apps.first { abs($0.key.count - s.count) <= 1 && editDistance($0.key, s) <= 1 }?.value
    }

    /// True when some app's name starts with `spoken` plus more words ("google" -> "google chrome"),
    /// meaning we should not act before the user finishes the name.
    func isPrefixOfLongerName(_ spoken: String) -> Bool {
        let s = spoken.lowercased() + " "
        return apps.keys.contains { $0.hasPrefix(s) }
    }

    func startsName(_ word: String) -> Bool {
        let w = word.lowercased()
        return apps.keys.contains { $0 == w || $0.hasPrefix(w + " ") } || aliases.keys.contains { $0 == w || $0.hasPrefix(w + " ") }
    }
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var prev = Array(0...b.count), cur = prev
    for i in 1...max(a.count, 1) where !a.isEmpty {
        cur[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return a.isEmpty ? b.count : prev[b.count]
}
