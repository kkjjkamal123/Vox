import Foundation

/// Assistant-style commands: messaging, calendar, weather, math, conversions, maps, files, text tools, alarms.
/// `w` is normalized (lowercase, no punctuation); `raw` is the same words as spoken, for message bodies etc.
extension Parser {
    static func assistant(_ w: [String], raw: [String]) -> [Action]? {
        let phrase = w.joined(separator: " ")
        func rawTail(_ n: Int) -> String { raw.suffix(n).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        func rawRange(_ r: Range<Int>) -> String { raw[r].joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }

        // MARK: Messaging
        if let m = parseMessage(w) {
            let body = rawRange(m.bodyStart..<w.count)
            guard !body.isEmpty else { return nil }
            return [.message(to: m.name, body: body, via: m.channel)]
        }
        if let rest = dropLead(w, [["send", "an", "email", "to"], ["send", "email", "to"], ["email", "to"], ["write", "an", "email", "to"],
                                   ["compose", "an", "email", "to"], ["draft", "an", "email", "to"], ["mail"], ["email"]]), !rest.isEmpty {
            let start = w.count - rest.count
            let about = rest.firstIndex(of: "about").map { $0 + start }
            let saying = rest.firstIndex { ["saying", "that", "say"].contains($0) }.map { $0 + start }
            let nameEnd = [about, saying].compactMap { $0 }.min() ?? w.count
            let name = w[start..<nameEnd].joined(separator: " ")
            let subject = about.map { rawRange(($0 + 1)..<(saying ?? w.count)) }
            let body = saying.map { rawRange(($0 + 1)..<w.count) }
            return [.email(to: name.isEmpty ? nil : name, subject: subject?.nilIfEmpty, body: body?.nilIfEmpty)]
        }

        // MARK: Time
        if let rest = dropLead(w, [["set", "an", "alarm", "for"], ["set", "an", "alarm", "at"], ["set", "alarm", "for"], ["set", "an", "alarm"],
                                   ["set", "alarm"], ["alarm", "for"], ["alarm", "at"], ["wake", "me", "up", "at"], ["wake", "me", "at"],
                                   ["wake", "me", "up", "tomorrow", "at"]]), !rest.isEmpty {
            if rest.first == "in", let s = duration(Array(rest.dropFirst())) { return [.timer(s, label: rest.dropFirst().joined(separator: " "))] }
            return [.alarm(rest.joined(separator: " ").replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm"))]
        }
        if let rest = dropLead(w, [["wake", "me", "up", "in"], ["wake", "me", "in"]]), let s = duration(rest) {
            return [.timer(s, label: rest.joined(separator: " "))]
        }

        // MARK: Calendar
        if let rest = dropLead(w, [["add", "an", "event"], ["add", "a", "meeting"], ["add", "event"], ["add", "meeting"], ["add", "an", "appointment"],
                                   ["schedule", "a", "meeting"], ["schedule", "a", "call"], ["schedule", "meeting"], ["schedule"],
                                   ["create", "an", "event"], ["create", "event"], ["create", "a", "meeting"], ["book", "a", "meeting"]]), !rest.isEmpty {
            // Keep the kind of event in the title: "add meeting with Rahul …" -> "Meeting with Rahul".
            let lead = w.dropLast(rest.count)
            let kind = ["meeting", "call", "appointment"].first { lead.contains($0) }
            let title = rawTail(rest.count)
            return [.addEvent(kind.map { $0.capitalized + " " + title } ?? title)]
        }
        if phrase.hasSuffix("to my calendar") || phrase.hasSuffix("on my calendar"), w.first == "add" || w.first == "put" {
            return [.addEvent(rawRange(1..<(w.count - 3)))]
        }

        // MARK: Weather
        let weatherWords: Set<String> = ["weather", "temperature", "forecast", "rain", "raining", "umbrella", "hot", "cold", "sunny", "humid", "snow"]
        let verbsFirst: Set<String> = ["set", "convert", "play", "search", "open", "watch", "put", "listen", "type", "write", "google",
                                       "find", "look", "launch", "start", "make", "message", "text", "email", "whatsapp", "note", "remind"]
        if w.contains(where: weatherWords.contains), !w.contains(where: { Double($0) != nil }) || w.contains("weather"),
           !verbsFirst.contains(w[0]) {
            var place: String?
            if let i = w.lastIndex(of: "in") ?? w.lastIndex(of: "at"), i + 1 < w.count {
                let p = w[(i + 1)...].filter { !["today", "tomorrow", "right", "now", "outside", "this", "week", "the"].contains($0) }
                if !p.isEmpty { place = p.joined(separator: " ") }
            }
            if place == "here" { place = nil }
            let day = w.contains("tomorrow") ? 1 : 0
            let rain = w.contains { ["rain", "raining", "umbrella"].contains($0) }
            return [.weather(place: place, dayOffset: day, rain: rain)]
        }

        // MARK: Math & conversions
        if let c = Calc.parseConversion(w) ?? howMany(w) { return [.convert(c)] }
        if w.contains(where: { $0.contains(where: \.isNumber) }), let v = Calc.evaluate(phrase) {
            return [.say("\(Calc.format(v))")]
        }
        if let rest = dropLead(w, [["pick", "a", "random", "number"], ["random", "number"], ["give", "me", "a", "random", "number"]]) {
            let nums = rest.compactMap { Int($0) }
            let lo = nums.count >= 2 ? min(nums[0], nums[1]) : 1, hi = nums.count >= 2 ? max(nums[0], nums[1]) : 100
            return [.say("\(Int.random(in: lo...hi))")]
        }

        // MARK: Maps
        if let rest = dropLead(w, [["get", "directions", "to"], ["directions", "to"], ["give", "me", "directions", "to"], ["how", "do", "i", "get", "to"],
                                   ["route", "to"], ["drive", "to"], ["how", "far", "is"]]), !rest.isEmpty {
            return [.directions(rawTail(rest.count))]
        }
        if let rest = dropLead(w, [["where", "is"], ["where's"], ["show", "me", "on", "the", "map"], ["find", "on", "map"]]), !rest.isEmpty,
           !["my"].contains(rest[0]) {
            return [.mapSearch(rawTail(rest.count))]
        }
        if phrase.hasSuffix("near me") || phrase.hasSuffix("nearby"), w.count >= 2 {
            let n = phrase.hasSuffix("near me") ? 2 : 1
            let lead = ["find", "show", "search", "any", "is", "there", "a", "an", "the", "some"]
            let words = w.dropLast(n).drop { lead.contains($0) }
            return [.mapSearch(words.joined(separator: " ") + " near me")]
        }

        // MARK: Files
        if let rest = dropLead(w, [["open", "the", "file"], ["open", "file"], ["find", "the", "file"], ["find", "file"], ["find", "my"],
                                   ["open", "the", "document"], ["open", "document"], ["open", "my", "document"], ["search", "my", "files", "for"],
                                   ["open", "the", "pdf"], ["open", "pdf"], ["find", "the", "document"]]), !rest.isEmpty {
            let q = rest.filter { !["file", "document", "the", "called", "named"].contains($0) }
            if !q.isEmpty { return [.openFile(q.joined(separator: " "))] }
        }

        // MARK: Text tools (selection / page / clipboard)
        if let t = parseTextTool(w) { return [t] }

        // MARK: Misc
        if let rest = dropLead(w, [["find"], ["search", "this", "page", "for"], ["search", "the", "page", "for"], ["look", "for"]]),
           rest.count >= 3, Array(rest.suffix(2)) == ["on", "page"] || Array(rest.suffix(3)) == ["on", "this", "page"] {
            let n = Array(rest.suffix(2)) == ["on", "page"] ? 2 : 3
            return [.findOnPage(rawRange((w.count - rest.count)..<(w.count - n)))]
        }
        if let rest = dropLead(w, [["say"], ["repeat", "after", "me"], ["speak"]]), !rest.isEmpty { return [.say(rawTail(rest.count))] }
        if let rest = dropLead(w, [["set", "brightness", "to"], ["brightness", "to"], ["set", "the", "brightness", "to"], ["brightness"]]),
           let n = rest.compactMap({ Int($0.replacingOccurrences(of: "%", with: "")) }).first {
            return [.setBrightness(min(100, max(0, n)))]
        }
        if let rest = dropLead(w, [["open", "youtube", "and", "play"]]), !rest.isEmpty {   // after connector splitting fails
            return [.play(rawTail(rest.count), service: .youtube)]
        }
        return nil
    }

    // MARK: Helpers

    private struct MessageMatch { let name: String; let bodyStart: Int; let channel: Messaging.Channel }

    /// "message rahul saying I'm late", "send a whatsapp to mom that I reached", "text priya: see you soon"
    private static func parseMessage(_ w: [String]) -> MessageMatch? {
        let leads: [([String], Messaging.Channel)] = [
            (["send", "a", "whatsapp", "message", "to"], .whatsApp), (["send", "a", "whatsapp", "to"], .whatsApp),
            (["whatsapp", "message", "to"], .whatsApp), (["whatsapp", "to"], .whatsApp), (["whatsapp"], .whatsApp),
            (["send", "a", "message", "to"], .iMessage), (["send", "message", "to"], .iMessage), (["send", "a", "text", "to"], .iMessage),
            (["send", "an", "imessage", "to"], .iMessage), (["message", "to"], .iMessage), (["text", "to"], .iMessage),
            (["message"], .iMessage), (["text"], .iMessage), (["imessage"], .iMessage), (["send"], .iMessage),
        ]
        for (lead, channel) in leads where w.count > lead.count + 1 && Array(w.prefix(lead.count)) == lead {
            var ch = channel
            let rest = Array(w.dropFirst(lead.count))
            guard let sep = rest.firstIndex(where: { ["saying", "that", "say", "says", "with"].contains($0) }), sep > 0 else { continue }
            var nameWords = Array(rest[..<sep])
            if nameWords.suffix(2) == ["on", "whatsapp"] { nameWords.removeLast(2); ch = .whatsApp }
            // "send it to priya …", "send this to mom …"
            if nameWords.count >= 2, ["it", "this", "that"].contains(nameWords[0]), nameWords[1] == "to" { nameWords.removeFirst() }
            if nameWords.first == "to" { nameWords.removeFirst() }
            guard !nameWords.isEmpty, nameWords.count <= 4 else { continue }
            var bodyStart = lead.count + sep + 1
            if rest[sep] == "that", sep + 1 < rest.count, rest[sep + 1] == "says" { bodyStart += 1 }
            guard bodyStart < w.count else { continue }
            return MessageMatch(name: nameWords.joined(separator: " "), bodyStart: bodyStart, channel: ch)
        }
        return nil
    }

    /// "how many grams in 2 pounds", "how many cm in an inch"
    private static func howMany(_ w: [String]) -> Calc.Conversion? {
        guard let rest = dropLead(w, [["how", "many"], ["how", "much"]]), let i = rest.firstIndex(of: "in"), i > 0, i + 1 < rest.count else { return nil }
        var tail = Array(rest[(i + 1)...])
        if tail.first == "a" || tail.first == "an" || tail.first == "one" { tail[0] = "1" }
        return Calc.parseConversion(["convert"] + tail + ["to"] + rest[..<i].filter { $0 != "are" })
    }

    private static func parseTextTool(_ w: [String]) -> Action? {
        let targets: [String: Action.TextSource] = [
            "this": .selection, "that": .selection, "it": .selection, "selection": .selection, "the selection": .selection,
            "selected text": .selection, "the selected text": .selection, "this text": .selection, "this message": .selection,
            "this email": .selection, "this page": .page, "the page": .page, "this article": .page, "the article": .page,
            "this website": .page, "this webpage": .page, "page": .page, "article": .page, "clipboard": .clipboard,
            "my clipboard": .clipboard, "the clipboard": .clipboard, "what i copied": .clipboard, "this document": .page,
        ]
        func source(_ rest: ArraySlice<String>) -> Action.TextSource? { targets[rest.joined(separator: " ")] }

        let verbs: [(String, TextTools.Operation)] = [("summarize", .summarize), ("summarise", .summarize), ("explain", .explain),
                                                      ("read", .read), ("proofread", .fixGrammar), ("reply", .reply)]
        for (v, op) in verbs where w.first == v {
            var rest = w.dropFirst()
            if v == "read", rest.last == "out" || rest.last == "aloud" { rest = rest.dropLast() }
            if v == "reply", rest.first == "to" { rest = rest.dropFirst() }
            if let s = source(rest) { return .text(op, source: s) }
            if rest.isEmpty, v != "read" { return .text(op, source: .selection) }
        }
        if w.first == "translate", let i = w.firstIndex(where: { $0 == "to" || $0 == "into" }), i + 1 < w.count,
           let s = source(w[1..<i]) ?? (i == 1 ? .selection : nil) {
            return .text(.translate(w[(i + 1)...].joined(separator: " ").capitalized), source: s)
        }
        if ["fix", "correct", "check"].contains(w.first ?? ""), w.contains(where: { ["grammar", "spelling", "typos"].contains($0) }) {
            return .text(.fixGrammar, source: .selection)
        }
        // "make this more formal", "rewrite this to sound professional", "make it shorter"
        if (w.first == "make" || w.first == "rewrite"), w.count >= 3, source(w[1...1]) == .selection {
            let style = w.dropFirst(2).filter { !["more", "to", "be", "sound", "a", "bit", "little", "it", "as"].contains($0) }.joined(separator: " ")
            if !style.isEmpty { return .text(.rewrite("more " + style), source: .selection) }
        }
        return nil
    }

    private static func dropLead(_ w: [String], _ leads: [[String]]) -> [String]? {
        for l in leads where w.count >= l.count && Array(w.prefix(l.count)) == l { return Array(w.dropFirst(l.count)) }
        return nil
    }
}
