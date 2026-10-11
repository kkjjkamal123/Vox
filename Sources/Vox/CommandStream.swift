import Foundation

/// Turns a growing, partially-revisable transcript into actions *while the user is still talking*.
///
/// The transcript is `final` text (never revised) plus a `volatile` tail (the recognizer's current guess).
/// A cursor over the combined words marks what has already been acted on. A clause runs as soon as:
///  - it's followed by "and"/"then"/punctuation and the next word starts a new command, or
///  - it's a closed command ("open safari", "new tab") whose words held steady across two updates, or
///  - the recognizer finalized it (a pause), or the session ended.
/// Dictation ("type ...") is streamed into the focused app word by word and corrected in place when
/// the recognizer revises a word.
@MainActor
final class CommandStream {
    var emit: (Action) -> Void = { _ in }
    var onUnparsed: (String) -> Void = { _ in }

    private var consumed = 0
    private var lastVerb: Verb?
    private var lastSite: String?
    private var pendingKey = ""
    private var dictating = false
    private var typed = ""

    private static let stopPhrases: [[String]] = [
        ["stop", "typing"], ["stop", "dictation"], ["stop", "dictating"], ["done", "typing"], ["end", "dictation"],
        ["stop", "writing"], ["finish", "typing"], ["end", "typing"], ["finished", "typing"],
    ]
    private static let fillers: Set<String> = ["please", "um", "uh", "okay", "ok", "so", "now", "just", "hey", "alright", "oh", ""]
    /// Words that clearly start a new command even without "and" before them.
    private static let explicitVerbs: Set<String> = ["open", "launch", "search", "type", "write", "dictate", "quit", "close", "press"]

    func reset() {
        lastFinal = ""; lastVolatile = ""
        consumed = 0; lastVerb = nil; lastSite = nil; pendingKey = ""; dictating = false; typed = ""; ran = 0
    }

    private var lastFinal = "", lastVolatile = ""
    var isDictating: Bool { dictating }
    /// Waiting only to see whether a short command ("stop", "next", "quit") goes on; if the user has stopped
    /// talking, the session can end (and run it) sooner.
    private(set) var holding = false
    /// Commands run since the last reset (a short leftover after one is a fragment, not a request).
    private(set) var ran = 0

    func update(final: String, volatile: String) {
        lastFinal = final; lastVolatile = volatile
        process(final: final, volatile: volatile, ended: false)
    }

    /// The recognizer's guess hasn't changed for a moment: treat it as final instead of waiting for the
    /// recognizer to commit (which can take a second or more). This is the main latency win for
    /// open-ended commands like "search …" or "play …".
    func settle() {
        guard !lastVolatile.isEmpty else { return }
        process(final: lastFinal + " " + lastVolatile, volatile: "", ended: false)
    }
    func finish(final: String) { process(final: final, volatile: "", ended: true) }

    /// Run a complete command string (used for language-model rewrites).
    func runOnce(_ text: String) { reset(); finish(final: text) }

    private func tokens(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func process(final: String, volatile: String, ended: Bool) {
        holding = false
        let finalWords = tokens(final)
        let words = finalWords + tokens(volatile)
        let finalCount = finalWords.count
        let norm = words.map(Parser.normalize)

        while consumed < words.count {
            if dictating {
                if stepDictation(words, norm, finalCount: finalCount, ended: ended) { continue }
                return
            }
            let n = norm[consumed]
            // A wake phrase said mid-session ("hey vox, open …") is not part of the command.
            if Wake.anyLead.contains(n) {
                if consumed + 1 >= words.count { if ended { consumed += 1; continue } else { return } }   // wait: "hey" … "vox"?
                if let m = Wake.find([n, norm[consumed + 1]]), m.strong { consumed += m.next; continue }
            }
            if Wake.fused.contains(n) { consumed += 1; continue }
            if Parser.connectors.contains(n) || Self.fillers.contains(n) {
                // "next song", "next tab": here the connector is the command itself.
                if Parser.fixed.keys.contains(where: { $0.hasPrefix(n + " ") }), consumed + 1 >= words.count, !ended { return }
                // A lone "next" at the end of a request means the next track.
                let alone = consumed + 1 == words.count && Parser.fixed[n] != nil
                if !startsFixed(norm, at: consumed) && !alone { consumed += 1; continue }
            }
            if ["can", "could", "would", "will"].contains(n), consumed + 1 < words.count, norm[consumed + 1] == "you" { consumed += 2; continue }

            // "write an email to …" / "write a note …" are commands, not dictation.
            if n == "write" {
                if consumed + 1 >= words.count, !ended { return }
                if consumed + 1 < words.count, ["an", "a", "email", "message", "to", "note", "mail"].contains(norm[consumed + 1]) {
                    // fall through to command parsing below
                } else if Parser.dictationVerbs.contains(n) {
                    consumed += 1
                    dictating = true; typed = ""; pendingKey = ""
                    emit(.beginDictation)
                    continue
                }
            } else if Parser.dictationVerbs.contains(n), n != "typing" {
                consumed += 1
                if consumed < words.count, ["out", "this", "that"].contains(norm[consumed]) && words[consumed].hasSuffix(":") { consumed += 1 }
                dictating = true; typed = ""; pendingKey = ""
                emit(.beginDictation)
                continue
            }

            // Find where this clause ends.
            var end = words.count
            var boundary = false
            var i = consumed + 1
            while i < words.count {
                if let last = words[i - 1].last, ".,;!?".contains(last) { end = i; boundary = true; break }
                if Parser.connectors.contains(norm[i]) {
                    var j = i + 1
                    while j < words.count, Parser.connectors.contains(norm[j]), !startsFixed(norm, at: j) { j += 1 }
                    if j < words.count, Parser.startsCommand(norm[j]) { end = i; boundary = true; break }
                }
                i += 1
            }
            let clause = Array(words[consumed..<end])
            let settled = boundary || end <= finalCount || ended

            if let p = Parser.parse(clause, lastVerb: lastVerb, site: lastSite) {
                // "quit…", "close this…", "play…", "lock…": the start of a longer command, said with a pause.
                // Running it now would press ⌘Q on the front app or resume the old song. Wait until the user
                // goes on or the request is over, even if the recognizer already finalized the word.
                if p.prefixOfLonger, !ended, !boundary, end == words.count { pendingKey = ""; holding = true; return }
                if settled {
                    run(p); consumed = end; continue
                }
                // The user is still talking. Act early only on closed commands.
                // A lone word ("play", "quit", "close") is often the start of a longer command, so wait.
                guard p.eager, end - consumed >= 2 else { pendingKey = ""; return }
                let key = norm[consumed..<end].joined(separator: " ")
                if key == pendingKey { run(p); consumed = end; continue }
                pendingKey = key
                return
            }

            // "open safari and" — the clause before a trailing connector is complete.
            if end - consumed >= 2, Parser.connectors.contains(norm[end - 1]),
               let p = Parser.parse(Array(clause.dropLast()), lastVerb: lastVerb, site: lastSite), p.eager {
                run(p); consumed = end - 1; continue
            }

            // No parse: maybe a new command starts mid-clause ("blah blah open notes", "open notes type hi").
            if let j = (consumed + 1..<end).first(where: { Self.explicitVerbs.contains(norm[$0]) && startsParsable(words, norm, from: $0, to: end) }) {
                let prefix = Array(words[consumed..<j])
                if let p = Parser.parse(prefix, lastVerb: lastVerb, site: lastSite) {
                    guard j <= finalCount || p.eager || ended else { return }
                    run(p)
                } else if j <= finalCount || ended {
                    onUnparsed(prefix.joined(separator: " "))
                } else { return }
                consumed = j; continue
            }

            if (boundary && end <= finalCount) || ended {
                onUnparsed(clause.joined(separator: " "))
                consumed = end; continue
            }
            return
        }
    }

    /// "next song", "next tab": a connector word that begins a fixed command.
    private func startsFixed(_ norm: [String], at i: Int) -> Bool {
        guard i + 1 < norm.count else { return false }
        let two = norm[i] + " " + norm[i + 1]
        return Parser.fixed.keys.contains { $0 == two || $0.hasPrefix(two + " ") }
    }

    private func startsParsable(_ words: [String], _ norm: [String], from j: Int, to end: Int) -> Bool {
        Parser.dictationVerbs.contains(norm[j]) || Parser.parse(Array(words[j..<end]), lastVerb: nil, site: nil) != nil
    }

    private func run(_ p: Parsed) {
        ran += 1
        p.actions.forEach(emit)
        lastVerb = p.verb
        if let site = p.site { lastSite = site }
        pendingKey = ""
    }

    /// Returns true if dictation ended and command parsing should resume.
    private func stepDictation(_ words: [String], _ norm: [String], finalCount: Int, ended: Bool) -> Bool {
        var stopAt: Int?
        search: for i in consumed..<words.count {
            for p in Self.stopPhrases where i + p.count <= words.count && Array(norm[i..<i + p.count]) == p {
                stopAt = i; break search
            }
        }
        let endIdx = stopAt ?? words.count
        // Hold back the newest volatile word: it's the one most likely to be revised.
        var hold = (stopAt == nil && !ended && endIdx > finalCount) ? 1 : 0
        // Also hold a word that may be the start of "new line" or "stop typing".
        if stopAt == nil, !ended, endIdx - hold > consumed,
           ["new", "stop", "done", "end", "finish", "finished"].contains(norm[endIdx - hold - 1]) { hold += 1 }
        var target = render(words[consumed..<max(consumed, endIdx - hold)])
        if stopAt != nil { target = target.trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
        sync(target)

        if let s = stopAt {
            consumed = s + 2; dictating = false; typed = ""
            return true
        }
        if ended { consumed = words.count; dictating = false; typed = "" }
        return false
    }

    private func render(_ slice: ArraySlice<String>) -> String {
        var out = ""
        var it = Array(slice)[...]
        while let w = it.first {
            it = it.dropFirst()
            let n = Parser.normalize(w)
            if n == "new", let next = it.first.map(Parser.normalize), next == "line" || next == "paragraph" {
                it = it.dropFirst()
                out = out.trimmingCharacters(in: .whitespaces) + (next == "line" ? "\n" : "\n\n")
                continue
            }
            if !out.isEmpty && !out.hasSuffix("\n") { out += " " }
            out += w
        }
        return out
    }

    /// Minimal edit from what's on screen to what the recognizer now believes was said.
    private func sync(_ target: String) {
        let a = Array(typed), b = Array(target)
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        if a.count > common { emit(.backspace(a.count - common)) }
        if b.count > common { emit(.type(String(b[common...]))) }
        typed = target
    }
}
