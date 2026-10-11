import Foundation

/// Everything Vox can do. The parser produces these; the executor carries them out.
enum Action: CustomStringConvertible {
    // Apps, web, keys
    case openApp(AppIndex.App)
    case openURL(URL, label: String, browser: AppIndex.App?)
    case quitApp(AppIndex.App)
    case quitAll
    case keys(Key.Combo, label: String)
    case findOnPage(String)
    case openPath(String, label: String)
    case openFile(String)
    // Media
    case play(String, service: Settings.MusicService?)
    case nowPlaying
    case player(Player.Command)
    case media(Int32, label: String)
    case setVolume(Int)
    case setBrightness(Int)
    // System
    case shell(String, [String], label: String)
    case appleScript(String, label: String)
    case wifi(Bool)
    case power(SystemControl.Power)
    case emptyTrash
    case storage
    case runShortcut(String)
    // Time & organization
    case timer(Int, label: String)
    case alarm(String)
    case cancelTimers
    case timeLeft
    case reminder(String, inSeconds: Int?)
    case makeNote(String)
    case addEvent(String)
    case agenda(dayOffset: Int)
    case nextEvent
    // Information
    case weather(place: String?, dayOffset: Int, rain: Bool)
    case convert(Calc.Conversion)
    case say(String)
    case ask(String)
    case speakInfo(Info)
    case directions(String)
    case mapSearch(String)
    // Text & communication
    case text(TextTools.Operation, source: TextSource)
    case message(to: String, body: String, via: Messaging.Channel)
    case email(to: String?, subject: String?, body: String?)
    // Dictation & control
    case beginDictation
    case type(String)
    case backspace(Int)
    case confirm(Bool)
    case send
    case stopListening

    enum Info { case time, date, battery }
    enum TextSource { case selection, page, clipboard }

    /// SF Symbol for the HUD chip.
    var symbol: String {
        switch self {
        case .openApp: return "app.badge.checkmark"
        case .openURL: return "safari"
        case .quitApp, .quitAll: return "xmark.app"
        case .keys: return "command"
        case .findOnPage: return "text.magnifyingglass"
        case .openPath, .openFile: return "folder.fill"
        case .play(_, let s): return s == .youtube ? "play.rectangle.fill" : "music.note"
        case .nowPlaying: return "music.note"
        case .player(let c): return c == .next ? "forward.fill" : c == .previous ? "backward.fill" : c == .pause ? "pause.fill" : "playpause.fill"
        case .media(let k, _): return k <= 1 || k == 7 ? "speaker.wave.2.fill" : "sun.max.fill"
        case .setVolume: return "speaker.wave.3.fill"
        case .setBrightness: return "sun.max.fill"
        case .shell, .appleScript: return "gearshape.fill"
        case .wifi: return "wifi"
        case .power: return "power"
        case .emptyTrash: return "trash.fill"
        case .storage: return "internaldrive.fill"
        case .runShortcut: return "square.2.layers.3d"
        case .timer, .cancelTimers, .timeLeft: return "timer"
        case .alarm: return "alarm.fill"
        case .reminder: return "checklist"
        case .makeNote: return "note.text"
        case .addEvent, .agenda, .nextEvent: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .convert: return "arrow.left.arrow.right"
        case .say: return "equal.circle.fill"
        case .ask: return "sparkles"
        case .speakInfo(let i): return i == .battery ? "battery.75percent" : "clock.fill"
        case .directions, .mapSearch: return "map.fill"
        case .text: return "text.quote"
        case .message(_, _, let via): return via == .whatsApp ? "phone.bubble.fill" : "message.fill"
        case .email: return "envelope.fill"
        case .beginDictation, .type, .backspace: return "character.cursor.ibeam"
        case .confirm(let yes): return yes ? "checkmark" : "xmark"
        case .send: return "paperplane.fill"
        case .stopListening: return "moon.zzz.fill"
        }
    }

    var description: String {
        switch self {
        case .openApp(let a): return "Open \(a.name)"
        case .openURL(_, let l, let b): return b.map { "Open \(l) in \($0.name)" } ?? "Open \(l)"
        case .quitApp(let a): return "Quit \(a.name)"
        case .quitAll: return "Quit all apps"
        case .keys(_, let l), .media(_, let l), .shell(_, _, let l), .appleScript(_, let l): return l
        case .findOnPage(let q): return "Find \"\(q)\""
        case .openPath(_, let l): return l
        case .openFile(let q): return "Open file \(q)"
        case .play(let q, let s): return "Play \(q)" + (s.map { " on \($0.title)" } ?? "")
        case .nowPlaying: return "What's playing"
        case .player(let c): return c.label
        case .setVolume(let v): return "Volume \(v)%"
        case .setBrightness(let v): return "Brightness \(v)%"
        case .wifi(let on): return "Wi-Fi \(on ? "on" : "off")"
        case .power(let p): return p.rawValue.capitalized
        case .emptyTrash: return "Empty Trash"
        case .storage: return "Storage"
        case .runShortcut(let n): return "Shortcut: \(n)"
        case .timer(_, let l): return "Timer \(l)"
        case .alarm(let t): return "Alarm \(t)"
        case .cancelTimers: return "Cancel timers"
        case .timeLeft: return "Time left"
        case .reminder(let t, _): return "Reminder: \(t)"
        case .makeNote(let t): return "Note: \(t)"
        case .addEvent(let t): return "Event: \(t)"
        case .agenda(let d): return d == 0 ? "Today's calendar" : "Tomorrow's calendar"
        case .nextEvent: return "Next event"
        case .weather(let p, let d, _): return "Weather" + (p.map { " in \($0.capitalized)" } ?? "") + (d == 1 ? " tomorrow" : "")
        case .convert(let c): return "Convert \(Calc.format(c.amount)) \(c.from) to \(c.to)"
        case .say(let s): return s == "__coin" ? "Flip a coin" : s == "__dice" ? "Roll a die" : s
        case .ask(let q): return q
        case .speakInfo(let i): return i == .time ? "Time" : i == .date ? "Date" : "Battery"
        case .directions(let p): return "Directions to \(p)"
        case .mapSearch(let p): return "Map: \(p)"
        case .text(let op, let src): return op.label + (src == .page ? " page" : src == .clipboard ? " clipboard" : "")
        case .message(let to, _, let via): return (via == .whatsApp ? "WhatsApp " : "Message ") + to
        case .email(let to, _, _): return "Email" + (to.map { " \($0)" } ?? "")
        case .beginDictation: return "Start typing"
        case .type(let s): return "Type \"\(s.replacingOccurrences(of: "\n", with: "⏎"))\""
        case .backspace(let n): return "Erase \(n)"
        case .confirm(let yes): return yes ? "Yes" : "No"
        case .send: return "Send"
        case .stopListening: return "Stop listening"
        }
    }
}
