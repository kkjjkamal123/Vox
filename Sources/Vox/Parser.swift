import Foundation

enum Verb { case open, search, close, other }

struct Parsed {
    var actions: [Action]
    /// Safe to run while the user is still mid-sentence: the command takes no open-ended argument.
    var eager: Bool
    var verb: Verb
    /// Site opened by this command, so a following "search X" searches there.
    var site: String? = nil
    /// A whole command that also begins a longer one ("quit" / "quit spotify", "play" / "play X"): don't run
    /// it while more words may follow.
    var prefixOfLonger = false
}

/// Deterministic, allocation-light command grammar. Handles the common cases instantly so the
/// language model is only woken up for phrasing this can't understand.
enum Parser {
    static let connectors: Set<String> = ["and", "then", "also", "plus", "after", "next"]
    static let dictationVerbs: Set<String> = ["type", "write", "dictate", "typing"]

    static let browsers = ["safari", "google chrome", "arc", "firefox", "brave browser", "microsoft edge", "orion", "zen"]

    static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "google": "https://www.google.com", "gmail": "https://mail.google.com",
        "github": "https://github.com", "reddit": "https://www.reddit.com", "twitter": "https://x.com", "x": "https://x.com",
        "facebook": "https://www.facebook.com", "instagram": "https://www.instagram.com", "linkedin": "https://www.linkedin.com",
        "netflix": "https://www.netflix.com", "amazon": "https://www.amazon.com", "wikipedia": "https://www.wikipedia.org",
        "chatgpt": "https://chatgpt.com", "chat gpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "whatsapp web": "https://web.whatsapp.com", "stack overflow": "https://stackoverflow.com",
        "google drive": "https://drive.google.com", "google docs": "https://docs.google.com",
        "google maps": "https://maps.google.com", "youtube music": "https://music.youtube.com",
        "spotify web": "https://open.spotify.com", "hacker news": "https://news.ycombinator.com",
    ]

    static let searchEngines: [String: String] = [
        "google": "https://www.google.com/search?q=", "youtube": "https://www.youtube.com/results?search_query=",
        "amazon": "https://www.amazon.com/s?k=", "wikipedia": "https://en.wikipedia.org/w/index.php?search=",
        "github": "https://github.com/search?q=", "reddit": "https://www.reddit.com/search/?q=",
        "bing": "https://www.bing.com/search?q=", "duckduckgo": "https://duckduckgo.com/?q=",
        "google maps": "https://www.google.com/maps/search/", "maps": "https://www.google.com/maps/search/",
        "spotify": "spotify:search:", "apple music": "music://music.apple.com/search?term=", "music": "music://music.apple.com/search?term=",
    ]

    private static func cmd(_ k: String, _ m: Key.Mods = .cmd) -> Key.Combo { Key.Combo(key: Key.code[k]!, mods: m) }

    /// Whole-clause commands (after fillers and articles are removed).
    static let fixed: [String: Action] = {
        var f: [String: Action] = [:]
        func add(_ phrases: [String], _ a: Action) { for p in phrases { f[p] = a } }
        add(["new tab", "open new tab", "open tab"], .keys(cmd("t"), label: "New tab"))
        add(["new window", "open new window"], .keys(cmd("n"), label: "New window"))
        add(["new note", "new document", "new file"], .keys(cmd("n"), label: "New document"))
        add(["close tab", "close this tab", "close", "close this", "close window", "close this window"], .keys(cmd("w"), label: "Close"))
        add(["reopen tab", "reopen closed tab", "undo close tab"], .keys(cmd("t", [.cmd, .shift]), label: "Reopen tab"))
        add(["next tab"], .keys(cmd("tab", .ctrl), label: "Next tab"))
        add(["previous tab", "last tab"], .keys(cmd("tab", [.ctrl, .shift]), label: "Previous tab"))
        add(["go back", "back"], .keys(cmd("["), label: "Back"))
        add(["go forward", "forward"], .keys(cmd("]"), label: "Forward"))
        add(["refresh", "reload", "refresh page", "reload page", "refresh this page", "reload this page"], .keys(cmd("r"), label: "Reload"))
        add(["scroll down", "page down"], .keys(cmd("pagedown", []), label: "Scroll down"))
        add(["scroll up", "page up"], .keys(cmd("pageup", []), label: "Scroll up"))
        add(["scroll to top", "go to top", "top of page"], .keys(cmd("up"), label: "Top"))
        add(["scroll to bottom", "go to bottom", "bottom of page"], .keys(cmd("down"), label: "Bottom"))
        add(["copy", "copy this", "copy that", "copy it"], .keys(cmd("c"), label: "Copy"))
        add(["paste", "paste it", "paste that", "paste this"], .keys(cmd("v"), label: "Paste"))
        add(["cut", "cut this", "cut that"], .keys(cmd("x"), label: "Cut"))
        add(["undo", "undo that"], .keys(cmd("z"), label: "Undo"))
        add(["redo", "redo that"], .keys(cmd("z", [.cmd, .shift]), label: "Redo"))
        add(["select all", "select everything"], .keys(cmd("a"), label: "Select all"))
        add(["save", "save this", "save it", "save file"], .keys(cmd("s"), label: "Save"))
        add(["find", "find on page"], .keys(cmd("f"), label: "Find"))
        add(["print", "print this"], .keys(cmd("p"), label: "Print"))
        add(["zoom in", "bigger"], .keys(cmd("="), label: "Zoom in"))
        add(["zoom out", "smaller"], .keys(cmd("-"), label: "Zoom out"))
        add(["full screen", "fullscreen", "go full screen", "enter full screen", "exit full screen"], .keys(cmd("f", [.cmd, .ctrl]), label: "Full screen"))
        add(["minimize", "minimize this", "minimize window"], .keys(cmd("m"), label: "Minimize"))
        add(["hide", "hide this", "hide app"], .keys(cmd("h"), label: "Hide"))
        add(["quit", "quit this", "quit app", "quit this app", "close app", "close this app"], .keys(cmd("q"), label: "Quit app"))
        add(["switch window", "next window"], .keys(cmd("`"), label: "Next window"))
        add(["mission control", "show all windows"], .keys(cmd("up", .ctrl), label: "Mission Control"))
        add(["spotlight", "open spotlight"], .keys(cmd("space"), label: "Spotlight"))
        add(["enter", "press enter", "hit enter", "submit", "press return", "new line"], .keys(cmd("return", []), label: "Enter"))
        add(["yes", "yeah", "yep", "yup", "confirm", "do it", "go ahead", "sure", "ok do it", "yes please", "correct",
             "haan", "ha", "han"], .confirm(true))
        // Confirms a pending question, or presses Return to send what's typed. "Yes" alone never presses keys.
        add(["send", "send it", "send that", "send this", "send message", "send the message"], .send)
        add(["no", "nope", "don't", "dont", "no thanks", "don't send", "dont send", "nahi", "na"], .confirm(false))
        add(["escape", "press escape", "hit escape"], .keys(cmd("escape", []), label: "Escape"))
        add(["volume up", "turn up the volume", "turn volume up", "turn it up", "louder", "increase volume", "raise volume"], .media(0, label: "Volume up"))
        add(["volume down", "turn down the volume", "turn volume down", "turn it down", "quieter", "decrease volume", "lower volume"], .media(1, label: "Volume down"))
        add(["mute", "unmute", "mute volume", "mute sound"], .media(7, label: "Mute"))
        add(["brightness up", "increase brightness", "brighter", "make the screen brighter", "make screen brighter", "screen brighter",
             "raise brightness"], .media(2, label: "Brightness up"))
        add(["brightness down", "decrease brightness", "dimmer", "dim screen", "dim the screen", "darker", "make the screen darker",
             "make screen darker", "reduce brightness", "lower brightness", "screen darker"], .media(3, label: "Brightness down"))
        add(["play pause", "play/pause", "toggle music"], .player(.toggle))
        add(["play", "resume", "play music", "resume music", "resume the music", "resume playback", "continue playing", "unpause",
             "play video", "resume video", "resume the song", "play it again"], .player(.play))
        add(["pause", "pause music", "pause the music", "stop music", "stop the music", "pause video", "pause the video", "stop the song",
             "pause the song", "pause song", "stop playing", "stop playback", "pause it", "stop", "stop it"], .player(.pause))
        add(["next", "next track", "next song", "skip", "skip song", "skip track", "play the next song", "play next song", "skip this song",
             "skip this", "change the song", "change song", "next video", "next one", "play the next one"], .player(.next))
        add(["previous track", "previous song", "last song", "play the previous song", "play previous song", "go back a song",
             "play the last song", "play that again"], .player(.previous))
        add(["take screenshot", "screenshot", "take a screenshot", "capture screen"],
            .shell("/usr/sbin/screencapture", ["-x", NSHomeDirectory() + "/Desktop/Vox Screenshot.png"], label: "Screenshot"))
        add(["lock screen", "lock", "lock computer", "lock mac", "lock my mac"], .keys(cmd("q", [.cmd, .ctrl]), label: "Lock"))
        add(["sleep display", "turn off display", "turn off screen", "screen off"], .shell("/usr/bin/pmset", ["displaysleepnow"], label: "Display off"))
        add(["dark mode", "toggle dark mode", "turn on dark mode", "enable dark mode", "light mode", "turn on light mode", "turn off dark mode", "disable dark mode"],
            .appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode", label: "Toggle dark mode"))
        add(["what time is it", "what's the time", "time", "tell me the time", "whats the time", "what is the time"], .speakInfo(.time))
        add(["battery", "battery level", "how much battery", "how much battery is left", "whats my battery", "what's my battery", "battery percentage"], .speakInfo(.battery))
        add(["turn on wifi", "wifi on", "enable wifi", "switch on wifi", "connect wifi"], .wifi(true))
        add(["turn off wifi", "wifi off", "disable wifi", "switch off wifi", "disconnect wifi"], .wifi(false))
        add(["empty trash", "empty the trash", "empty bin", "empty recycle bin"], .emptyTrash)
        add(["quit all apps", "close all apps", "quit everything", "quit all applications", "close all applications", "quit all"], .quitAll)
        add(["shut down", "shutdown", "shut down the mac", "shut down my mac", "shut down the computer", "turn off the computer",
             "turn off my mac", "turn off the mac", "power off", "shut down computer"], .power(.shutdown))
        add(["restart", "reboot", "restart the mac", "restart my mac", "restart the computer", "restart computer", "reboot mac"], .power(.restart))
        add(["log out", "logout", "sign out", "log me out"], .power(.logout))
        add(["sleep", "go to sleep", "put the mac to sleep", "put my mac to sleep", "put the computer to sleep", "sleep mac",
             "sleep the mac", "sleep computer"], .power(.sleep))
        add(["how much storage", "storage", "disk space", "free space", "how much space", "how much storage do i have",
             "how much space do i have", "how much space is left", "storage left"], .storage)
        add(["what's the date", "whats the date", "what is the date", "what's today's date", "what day is it", "today's date", "date"], .speakInfo(.date))
        add(["what's playing", "whats playing", "what song is this", "what song is playing", "who sings this", "what's this song",
             "whats this song", "what is playing", "which song is this"], .nowPlaying)
        add(["cancel timer", "cancel the timer", "cancel my timer", "cancel timers", "cancel all timers", "stop timer", "stop the timer",
             "cancel alarm", "cancel the alarm", "cancel my alarm", "cancel alarms", "delete alarm", "delete my alarm", "stop alarm",
             "turn off alarm", "turn off the alarm"], .cancelTimers)
        add(["how much time is left", "how much time left", "time left", "how long is left", "check timer", "check my timer",
             "how much time is left on the timer", "how much time is left on my timer", "how long left"], .timeLeft)
        add(["what's on my calendar", "whats on my calendar", "what's on my calendar today", "what do i have today", "my schedule",
             "what's my schedule", "whats my schedule", "my schedule today", "what's my schedule today", "do i have any meetings today",
             "do i have any meetings", "what's on today", "agenda", "my agenda", "today's agenda", "what's on my schedule"], .agenda(dayOffset: 0))
        add(["what's on my calendar tomorrow", "whats on my calendar tomorrow", "what do i have tomorrow", "my schedule tomorrow",
             "what's my schedule tomorrow", "do i have any meetings tomorrow", "tomorrow's agenda", "what's on tomorrow"], .agenda(dayOffset: 1))
        add(["what's my next meeting", "whats my next meeting", "when is my next meeting", "next meeting", "what's next",
             "what's my next event", "next event", "what's next on my calendar"], .nextEvent)
        add(["read my clipboard", "read clipboard", "what's on my clipboard", "whats on my clipboard", "what's in my clipboard",
             "what did i copy", "read what i copied"], .text(.read, source: .clipboard))
        add(["flip a coin", "toss a coin", "heads or tails", "flip coin", "coin toss"], .say("__coin"))
        add(["roll a dice", "roll a die", "roll dice", "roll the dice"], .say("__dice"))
        add(["new folder", "create a folder", "create new folder"], .keys(cmd("n", [.cmd, .shift]), label: "New folder"))
        add(["bookmark this", "bookmark this page", "add bookmark"], .keys(cmd("d"), label: "Bookmark"))
        add(["private window", "incognito", "incognito window", "open private window", "open incognito window", "new private window"],
            .keys(cmd("n", [.cmd, .shift]), label: "Private window"))
        add(["address bar", "go to address bar", "focus address bar"], .keys(cmd("l"), label: "Address bar"))
        add(["minimize all", "minimize everything", "minimise all"], .keys(cmd("m", [.cmd, .opt]), label: "Minimize all"))
        add(["close all windows", "close everything"], .keys(cmd("w", [.cmd, .opt]), label: "Close all windows"))
        add(["maximize", "maximise", "maximize window", "maximise window", "fill screen", "fill window", "make it full"], .keys(cmd("f", [.ctrl, .fn]), label: "Fill window"))
        add(["center window", "centre window", "center this", "centre this"], .keys(cmd("c", [.ctrl, .fn]), label: "Center window"))
        add(["tile left", "move left", "snap left", "window left", "move window left"], .keys(cmd("left", [.ctrl, .fn]), label: "Tile left"))
        add(["tile right", "move right", "snap right", "window right", "move window right"], .keys(cmd("right", [.ctrl, .fn]), label: "Tile right"))
        add(["stop listening", "never mind", "nevermind", "cancel", "cancel that", "goodbye", "bye", "that's all", "thats all",
             "done", "thank you", "thanks", "shut up", "be quiet", "go away"], .stopListening)
        return f
    }()

    private static let leadingFillers: [[String]] = [
        ["go", "ahead", "and"], ["i", "want", "you", "to"], ["i", "want", "to"], ["i'd", "like", "to"], ["can", "you"],
        ["could", "you"], ["would", "you"], ["will", "you"], ["please"], ["hey"], ["ok"], ["okay"], ["um"], ["uh"],
        ["so"], ["now"], ["just"], ["and"], ["then"], ["also"], ["plus"], ["after", "that"], ["oh"], ["alright"],
        ["hello"], ["hi"], ["yaar"], ["bro"], ["dude"], ["quickly"],
    ]
    private static let trailingFillers: [[String]] = [["please"], ["for", "me"], ["now"], ["right", "now"], ["thanks"], ["thank", "you"],
                                                      ["yaar"], ["bro"], ["quickly"]]
    private static let articles: Set<String> = ["a", "an", "the", "my", "this", "that"]

    static let openVerbs: [[String]] = [["take", "me", "to"], ["navigate", "to"], ["switch", "to"], ["go", "to"], ["bring", "up"],
                                        ["pull", "up"], ["show", "me"], ["open", "up"], ["i", "want", "to", "see"], ["let", "me", "see"], ["see"], ["open"], ["launch"], ["start"], ["run"], ["visit"], ["show"]]
    static let searchVerbs: [[String]] = [["search", "for"], ["search"], ["look", "up"], ["google"], ["find"], ["play", "me"], ["play"],
                                          ["watch"], ["put", "on"], ["listen", "to"], ["i", "want", "to", "watch"], ["i", "want", "to", "listen", "to"]]
    static let closeVerbs: [[String]] = [["quit"], ["close"], ["kill"], ["exit"]]

    /// Phrases to bias the recognizer toward: the wake word, command vocabulary and site names.
    static var vocabulary: [String] {
        ["Hey Vox", "Vox", "Spotify", "YouTube", "Wi-Fi", "Safari", "Google", "WhatsApp", "Instagram", "timer", "remind me",
         "open", "search", "play", "type", "stop typing", "new tab", "close tab", "volume up", "volume down", "screenshot",
         "brightness", "dark mode", "shortcut", "maximize", "tile left", "tile right", "weather", "alarm", "calendar", "message",
         "email", "summarize", "translate", "directions", "convert", "Apple Music", "LTT", "MKBHD"]
            + sites.keys.map { $0.capitalized }
    }

    /// How much a transcript reads like something Vox can act on; used to choose among the recognizer's
    /// alternative transcriptions.
    static func score(_ text: String) -> Int {
        let w = text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        var score = 0
        if let m = Wake.find(w) { score += m.strong ? 6 : 3 }
        for word in w {
            if openVerbs.contains(where: { $0[0] == word }) || searchVerbs.contains(where: { $0[0] == word })
                || closeVerbs.contains(where: { $0[0] == word }) || dictationVerbs.contains(word) { score += 3 }
            else if sites[word] != nil || AppIndex.shared.exact(word) != nil { score += 2 }
            else if fixed.keys.contains(where: { $0.hasPrefix(word + " ") || $0 == word }) { score += 1 }
        }
        return score
    }

    static func normalize(_ raw: String) -> String {
        let n = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”()"))
        return n == "wi-fi" || n == "wi‑fi" ? "wifi" : n
    }

    /// Would a clause starting at `word` be a new command? Decides whether "and"/"then" splits a sentence.
    static func startsCommand(_ word: String) -> Bool {
        let w = normalize(word)
        if dictationVerbs.contains(w) || w == "press" || w == "hit" { return true }
        for list in [openVerbs, searchVerbs, closeVerbs] where list.contains(where: { $0.first == w }) { return true }
        if fixed.keys.contains(where: { $0 == w || $0.hasPrefix(w + " ") }) { return true }
        if ["new", "scroll", "volume", "set", "turn", "mute", "take", "lock", "copy", "paste", "save", "undo", "go", "zoom", "next", "previous",
            "select", "remind", "make", "run", "shortcut", "timer", "maximize", "maximise", "tile", "center", "centre", "empty", "note", "what",
            "who", "message", "text", "whatsapp", "email", "send", "weather", "schedule", "add", "wake", "cancel", "flip", "roll", "pick",
            "summarize", "summarise", "translate", "explain", "read", "fix", "rewrite", "reply", "shut", "restart", "reboot", "log",
            "directions", "navigate", "where", "convert", "calculate", "alarm", "put", "listen", "yes", "no", "how", "when", "is"].contains(w) { return true }
        return sites[w] != nil || AppIndex.shared.startsName(w)
    }

    static func parse(_ input: [String], lastVerb: Verb?, site: String? = nil) -> Parsed? {
        let pairs = input.map { ($0, normalize($0)) }.filter { !$0.1.isEmpty }
        var w = pairs.map(\.1)
        let (lead, trail) = stripFillers(&w)
        guard !w.isEmpty else { return nil }
        // Original words (with the recognizer's capitalization and punctuation), aligned with `w`.
        let raw = Array(pairs.map(\.0)[lead..<(pairs.count - trail)])
        let phrase = w.joined(separator: " ")
        let noArticles = w.filter { !articles.contains($0) }.joined(separator: " ")

        // A clause ending in "a", "the", "to"… isn't finished ("play a …", "cancel the …"): wait for more.
        if danglers.contains(w.last!) { return nil }
        if let a = fixed[phrase] ?? fixed[noArticles] {
            // Don't jump on "what's on my calendar" when "… tomorrow" may follow.
            let longer = fixed.keys.contains { $0.hasPrefix(phrase + " ") }
            // Only worth waiting for when the longer command does something else ("quit" vs "quit all apps",
            // "stop" vs "stop timer"); "pause" and "pause music" are the same. "quit spotify", "play kesariya"
            // and "find X" are longer commands too.
            let different = fixed.contains { $0.key.hasPrefix(phrase + " ") && $0.value.description != a.description }
            let verbLike = [openVerbs, searchVerbs, closeVerbs].contains { $0.contains { $0 == [phrase] } }
            // "send…" may become "send a message to …": never press Return mid-sentence.
            var sends = false
            if case .send = a { sends = true }
            return Parsed(actions: [a], eager: !longer, verb: .other, prefixOfLonger: different || verbLike || sends)
        }

        if w.first == "press" || w.first == "hit", let combo = Key.parseCombo(Array(w.dropFirst())) {
            return Parsed(actions: [.keys(combo, label: "Press " + w.dropFirst().joined(separator: " "))], eager: true, verb: .other)
        }
        if let v = parseVolume(w) { return Parsed(actions: [.setVolume(v)], eager: false, verb: .other) }
        if let a = assistant(w, raw: raw) {
            // "summarize" / "summarize this" may go on to "… this page": the source isn't settled yet.
            var open = false
            if case .text = a.first, ["summarize", "summarise", "explain", "read", "reply", "translate", "proofread"].contains(w[0]),
               w.count == 1 || ["this", "the", "my", "it", "that"].contains(w.last!) { open = true }
            return Parsed(actions: a, eager: false, verb: .other, prefixOfLonger: open)
        }

        if let rest = dropPrefix(w, anyOf: [["run", "the", "shortcut"], ["run", "shortcut"], ["shortcut"]]), !rest.isEmpty {
            return Parsed(actions: [.runShortcut(rest.joined(separator: " ").capitalized)], eager: false, verb: .other)
        }
        if let t = parseTimer(w) { return Parsed(actions: [t], eager: false, verb: .other) }
        if let rest = dropPrefix(w, anyOf: [["remind", "me", "to"], ["remind", "me"], ["add", "a", "reminder", "to"], ["add", "reminder"],
                                            ["create", "a", "reminder", "to"], ["set", "a", "reminder", "to"]]), !rest.isEmpty {
            var text = rest, secs: Int?
            if let i = text.lastIndex(of: "in"), let d = duration(Array(text[(i + 1)...])) { secs = d; text = Array(text[..<i]) }
            return Parsed(actions: [.reminder(text.joined(separator: " "), inSeconds: secs)], eager: false, verb: .other)
        }
        if let rest = dropPrefix(w, anyOf: [["make", "a", "note", "that"], ["make", "a", "note"], ["take", "a", "note"], ["note", "that"],
                                            ["create", "a", "note"], ["new", "note", "saying"], ["add", "a", "note"], ["note", "down"], ["jot", "down"],
                                            ["make", "note"], ["write", "a", "note"]]), !rest.isEmpty {
            return Parsed(actions: [.makeNote(raw.suffix(rest.count).joined(separator: " "))], eager: false, verb: .other)
        }
        if w[0] == "ask", w.count >= 2 { return Parsed(actions: [.ask(raw.dropFirst().joined(separator: " "))], eager: false, verb: .other) }
        if questionWords.contains(w[0]), w.count >= 3 {
            return Parsed(actions: [.ask(raw.joined(separator: " "))], eager: false, verb: .other)
        }

        if let rest = dropPrefix(w, anyOf: closeVerbs) {
            let target = stripArticles(rest).joined(separator: " ")
            if let f = fixed["close " + target] { return Parsed(actions: [f], eager: true, verb: .close) }
            if let app = AppIndex.shared.find(target) {
                return Parsed(actions: [.quitApp(app)], eager: AppIndex.shared.exact(target) != nil && !AppIndex.shared.isPrefixOfLongerName(target), verb: .close)
            }
            return nil
        }

        if let rest = dropPrefix(w, anyOf: openVerbs) {
            let isGoTo = ["go", "visit", "navigate", "take"].contains(w[0])
            if let p = resolveOpen(stripArticles(rest), guessWebsite: isGoTo && !["navigate", "take"].contains(w[0])) { return p }
            // "navigate to the airport", "take me to MG Road": not a website, so directions.
            if ["navigate", "take"].contains(w[0]), !rest.isEmpty { return Parsed(actions: [.directions(raw.suffix(rest.count).joined(separator: " "))], eager: false, verb: .other) }
            return nil
        }

        if let rest = dropPrefix(w, anyOf: searchVerbs), !rest.isEmpty {
            return parseSearch(rest, verb: w[0], site: site)
        }

        // Bare target after "open X and Y" (or on its own): "youtube", "notes". Without "open" just before it,
        // only an exact name counts: a stray leftover word ("screen") must not launch Screen Sharing.
        // After another kind of command ("quit all… apps") a leftover word is not something to open.
        if lastVerb == .open || lastVerb == nil,
           let p = resolveOpen(stripArticles(w), guessWebsite: false, fuzzy: lastVerb == .open) { return p }
        if lastVerb == .close, let app = AppIndex.shared.find(noArticles) { return Parsed(actions: [.quitApp(app)], eager: false, verb: .close) }
        return nil
    }

    private static func resolveOpen(_ words: [String], guessWebsite: Bool, fuzzy: Bool = true) -> Parsed? {
        var words = words.filter { !["app", "application", "website", "site", "page", "homepage"].contains($0) }
        guard !words.isEmpty else { return nil }
        // "... in chrome" / "... on safari"
        var browser: AppIndex.App?
        if words.count >= 3, ["in", "on", "using", "with"].contains(words[words.count - 2]),
           let b = AppIndex.shared.find(words.last!), browsers.contains(b.name.lowercased()) {
            browser = b; words.removeLast(2)
        }
        let target = words.joined(separator: " ")
        if let f = fixed["new " + target] ?? fixed[target], target.hasPrefix("new") || target == "tab" { return Parsed(actions: [f], eager: true, verb: .open) }
        if let path = folders[target] ?? folders[target.replacingOccurrences(of: " folder", with: "")] {
            return Parsed(actions: [.openPath(NSHomeDirectory() + path, label: "Open " + target.capitalized)], eager: false, verb: .open)
        }
        if target.hasSuffix(" settings") || target.hasSuffix(" preferences"),
           let pane = settingsPanes[String(target.split(separator: " ").dropLast().joined(separator: " "))] {
            return Parsed(actions: [.openURL(URL(string: "x-apple.systempreferences:" + pane)!, label: target.capitalized, browser: nil)], eager: false, verb: .open)
        }
        let index = AppIndex.shared
        let waitForMore = index.isPrefixOfLongerName(target) || sites.keys.contains { $0.hasPrefix(target + " ") }

        if browser == nil, let app = index.exact(target) { return Parsed(actions: [.openApp(app)], eager: !waitForMore, verb: .open) }
        if let site = sites[target] {
            return Parsed(actions: [.openURL(URL(string: site)!, label: target.capitalized, browser: browser)], eager: !waitForMore, verb: .open, site: target)
        }
        if fuzzy, browser == nil, let app = index.find(target) { return Parsed(actions: [.openApp(app)], eager: false, verb: .open) }
        if let url = urlFromSpoken(target, guess: guessWebsite) {
            return Parsed(actions: [.openURL(url, label: url.host ?? target, browser: browser)], eager: false, verb: .open)
        }
        return nil
    }

    private static func parseSearch(_ rest: [String], verb: String, site: String?) -> Parsed? {
        var q = rest
        let contextEngine = site.flatMap { searchEngines[$0] != nil ? $0 : nil }
        let isPlay = ["play", "watch", "put", "listen", "i"].contains(verb)
        var engine = contextEngine ?? "google"
        // "search youtube for cats"
        if q.count >= 3, let i = q.firstIndex(of: "for"), i > 0, searchEngines[q[..<i].joined(separator: " ")] != nil {
            engine = q[..<i].joined(separator: " "); q = Array(q[(i + 1)...])
        } else if q.count >= 3, ["on", "in", "using"].contains(q[q.count - 2]), searchEngines[q.last!] != nil {
            engine = q.last!; q.removeLast(2)
        } else if q.count >= 4, ["on", "in"].contains(q[q.count - 3]), searchEngines[q.suffix(2).joined(separator: " ")] != nil {
            engine = q.suffix(2).joined(separator: " "); q.removeLast(3)
        }
        let query = q.joined(separator: " ")
        if isPlay {
            guard !query.isEmpty else { return nil }
            // Name the service when it was said ("on spotify"), was just opened ("open youtube and play …"),
            // or is implied ("watch", "… video"); otherwise the user's default service decides.
            var service: Settings.MusicService?
            let explicit = rest.count != q.count
            if explicit || contextEngine != nil {
                switch engine {
                case "youtube": service = .youtube
                case "spotify": service = .spotify
                case "apple music", "music", "itunes": service = .appleMusic
                default: break
                }
            }
            if service == nil, verb == "watch" || q.contains(where: { ["video", "videos", "trailer", "vlog", "episode"].contains($0) }) { service = .youtube }
            // "play random…", "watch the latest…": the subject is still coming.
            let unfinished = ["random", "latest", "newest", "new", "recent"].contains(q.last ?? "")
            return Parsed(actions: [.play(query, service: service)], eager: false, verb: .search,
                          site: service == .youtube ? "youtube" : site, prefixOfLonger: unfinished)
        }
        guard !query.isEmpty, let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: searchEngines[engine]! + enc) else { return nil }
        return Parsed(actions: [.openURL(url, label: "\(engine.capitalized): \(query)", browser: nil)], eager: false, verb: .search)
    }

    private static func urlFromSpoken(_ t: String, guess: Bool) -> URL? {
        var s = t.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " ", with: "")
        let tlds = [".com", ".org", ".net", ".io", ".ai", ".dev", ".in", ".co", ".app", ".edu", ".gov"]
        if !tlds.contains(where: { s.contains($0) }) {
            guard guess, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
            s += ".com"
        }
        return URL(string: s.hasPrefix("http") ? s : "https://" + s)
    }

    static let folders: [String: String] = [
        "downloads": "/Downloads", "documents": "/Documents", "desktop": "/Desktop", "pictures": "/Pictures", "photos folder": "/Pictures",
        "movies": "/Movies", "home": "", "home folder": "", "applications folder": "/../../Applications", "download": "/Downloads",
    ]
    static let settingsPanes: [String: String] = [
        "wifi": "com.apple.wifi-settings-extension", "bluetooth": "com.apple.BluetoothSettings", "battery": "com.apple.Battery-Settings.extension",
        "display": "com.apple.Displays-Settings.extension", "displays": "com.apple.Displays-Settings.extension", "sound": "com.apple.Sound-Settings.extension",
        "notification": "com.apple.Notifications-Settings.extension", "notifications": "com.apple.Notifications-Settings.extension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension", "keyboard": "com.apple.Keyboard-Settings.extension",
        "network": "com.apple.Network-Settings.extension", "privacy": "com.apple.settings.PrivacySecurity.extension",
        "general": "com.apple.systempreferences.GeneralSettings", "focus": "com.apple.Focus-Settings.extension",
        "appearance": "com.apple.Appearance-Settings.extension", "trackpad": "com.apple.Trackpad-Settings.extension",
    ]

    /// "set a timer for 5 minutes", "timer 30 seconds"
    private static func parseTimer(_ w: [String]) -> Action? {
        guard let i = w.firstIndex(of: "timer"), i <= 3, let secs = duration(Array(w[(i + 1)...].drop { $0 == "for" || $0 == "of" })) else { return nil }
        let label = w[(i + 1)...].drop { $0 == "for" || $0 == "of" }.joined(separator: " ")
        return .timer(secs, label: label)
    }

    /// "5 minutes", "two hours", "30 seconds", "a minute", "half an hour"
    static func duration(_ w: [String]) -> Int? {
        let joined = w.joined(separator: " ")
        if joined.hasPrefix("half an hour") { return 1800 }
        var n: Int?, unit = 60
        for word in w {
            if n == nil { n = Int(word) ?? smallNumbers[word] ?? (["a", "an", "one"].contains(word) ? 1 : nil); continue }
            if word.hasPrefix("sec") { unit = 1 } else if word.hasPrefix("min") { unit = 60 } else if word.hasPrefix("hour") || word == "hr" { unit = 3600 } else { continue }
            break
        }
        return n.map { $0 * unit }
    }

    private static let smallNumbers: [String: Int] = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90]

    private static func parseVolume(_ w: [String]) -> Int? {
        guard let i = w.firstIndex(of: "volume"), w.count > i + 1 else { return nil }
        let nums = w[(i + 1)...].compactMap { word -> Int? in
            let d = word.replacingOccurrences(of: "%", with: "")
            return Int(d) ?? numberWords[d]
        }
        guard let n = nums.first else { return nil }
        return min(100, max(0, n))
    }

    private static let numberWords: [String: Int] = ["zero": 0, "ten": 10, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "max": 100, "maximum": 100, "half": 50]

    /// Removes politeness and filler; returns how many words were dropped from the front and back.
    @discardableResult
    static func stripFillers(_ w: inout [String]) -> (Int, Int) {
        var lead = 0, trail = 0
        var changed = true
        while changed {
            changed = false
            for f in leadingFillers where w.count > f.count && Array(w.prefix(f.count)) == f { w.removeFirst(f.count); lead += f.count; changed = true }
            for f in trailingFillers where w.count > f.count && Array(w.suffix(f.count)) == f { w.removeLast(f.count); trail += f.count; changed = true }
        }
        return (lead, trail)
    }

    static let danglers: Set<String> = ["a", "an", "the", "my", "some", "to", "for", "on", "in", "with", "at", "of", "your", "his",
                                        "her", "our", "their", "and", "then", "into", "about", "saying", "that's"]

    static let questionWords: Set<String> = ["what", "who", "how", "why", "when", "where", "which", "whats", "what's", "explain", "define",
                                             "tell", "is", "are", "does", "do", "can", "should", "translate", "who's", "whos", "how's"]

    private static func stripArticles(_ w: [String]) -> [String] {
        var w = w
        while let f = w.first, articles.contains(f), w.count > 1 { w.removeFirst() }
        return w
    }

    private static func dropPrefix(_ w: [String], anyOf verbs: [[String]]) -> [String]? {
        for v in verbs where w.count > v.count && Array(w.prefix(v.count)) == v { return Array(w.dropFirst(v.count)) }
        return nil
    }
}
