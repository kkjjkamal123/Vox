import AppKit
import AVFoundation
import IOKit.ps

/// Runs actions strictly in order and reports what actually happened. It waits for apps to come to the
/// front before sending them keystrokes, asks before anything irreversible (sending, shutting down), and
/// finishes a request instead of stopping halfway: "play X" plays X, it doesn't just search for it.
@MainActor
final class Executor: NSObject, AVSpeechSynthesizerDelegate {
    enum Outcome {
        case done
        case info(String)          // show and speak
        case failed(String)        // show in red and speak
        case asking(String)        // waiting for yes / no
    }

    var onDone: (Action, Outcome) -> Void = { _, _ in }
    /// A question for the user; the app keeps listening for "yes" or "no".
    var onPrompt: (String) -> Void = { _ in }
    var onStopListening: () -> Void = {}
    /// True while Vox is talking, so the listener can ignore its own voice.
    var onSpeaking: (Bool) -> Void = { _ in }

    private let brain: Brain
    private let settings = Settings.shared
    private var tail: Task<Void, Never>?
    private var browser: AppIndex.App?          // the browser most recently opened by voice
    private var justOpened: String?             // bundle id opened by the previous action
    private var lastYouTubeHome: Date?          // when "open youtube" last opened the homepage
    private var pending: (prompt: String, run: () async -> Outcome, expires: Date)?
    private let speech = AVSpeechSynthesizer()
    /// The utterance being spoken; only its own finish unmutes the mic.
    private var speaking: AVSpeechUtterance?

    nonisolated static let browserIDs: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac", "com.kagi.kagimacOS", "app.zen-browser.zen"]
    /// Apps where dictating right after launch should start a fresh document.
    private static let newDocApps: Set<String> = ["com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages"]

    init(brain: Brain) {
        self.brain = brain
        super.init()
        speech.delegate = self
    }

    func enqueue(_ action: Action) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            let busy = Self.busy()
            defer { ProcessInfo.processInfo.endActivity(busy) }
            let outcome = await self.perform(action)
            self.report(action, outcome)
        }
    }

    /// Keeps App Nap off while a command runs. Vox has no visible window once the popup hides, and macOS then
    /// delays its timers by tens of seconds, so "is the song playing yet?" checks stalled. Idle sleep stays allowed.
    nonisolated static func busy() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Running a voice command")
    }

    private func report(_ action: Action, _ outcome: Outcome) {
        switch outcome {
        case .done:
            if settings.feedback == .everything, !Self.silent(action) { speak(action.description) }
        case .info(let text):
            if settings.feedback != .quiet { speak(text) }
        case .failed(let text):
            if settings.feedback != .quiet { speak(text) }
            if settings.soundEffects { NSSound(named: "Basso")?.play() }
        case .asking(let q):
            speak(q)
            onPrompt(q)
        }
        onDone(action, outcome)
    }

    private static func silent(_ a: Action) -> Bool {
        switch a { case .type, .backspace, .beginDictation, .keys, .media, .player, .stopListening, .confirm, .send: return true; default: return false }
    }

    /// Ask before doing something that can't be undone. The answer arrives as a `.confirm` action.
    private func confirm(_ prompt: String, _ run: @escaping () async -> Outcome) -> Outcome {
        pending = (prompt, run, Date().addingTimeInterval(20))
        return .asking(prompt)
    }

    // MARK: Actions

    private func perform(_ action: Action) async -> Outcome {
        let opened = justOpened
        justOpened = nil
        switch action {
        case .openApp(let app):
            return await open(app) ? .done : .failed("I couldn't open \(app.name).")

        case .openURL(let url, _, let explicit):
            lastYouTubeHome = url.host?.hasSuffix("youtube.com") == true && url.path.count <= 1 ? Date() : nil
            if let target = explicit ?? browser, let id = Bundle(url: target.url)?.bundleIdentifier {
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: target.url, configuration: NSWorkspace.OpenConfiguration())
                await waitForFront(id)
            } else if !NSWorkspace.shared.open(url) {
                return .failed("I couldn't open that.")
            }
            return .done

        case .quitApp(let app):
            let id = Bundle(url: app.url)?.bundleIdentifier
            let running = NSWorkspace.shared.runningApplications.filter {
                id != nil ? $0.bundleIdentifier == id : $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
            }
            guard !running.isEmpty else { return .info("\(app.name) isn't open.") }
            running.forEach { $0.terminate() }
            return .done

        case .quitAll:
            let n = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count - 1
            return confirm("Quit all \(max(n, 0)) open apps?") { .info("Quit \(SystemControl.quitAllApps()) apps.") }

        case .keys(let combo, _):
            Keyboard.press(combo)
            try? await Task.sleep(for: .milliseconds(60))
            return .done

        case .findOnPage(let q):
            Keyboard.press(Key.Combo(key: Key.code["f"]!, mods: .cmd))
            try? await Task.sleep(for: .milliseconds(200))
            Keyboard.type(q)
            Keyboard.press(Key.Combo(key: Key.code["return"]!, mods: []))
            return .done

        case .openPath(let path, _):
            let p = (path as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: p) else { return .failed("That folder doesn't exist.") }
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            return .done

        case .openFile(let q):
            if let name = await SystemControl.openFile(q) { return .info("Opening \(name).") }
            return .failed("I couldn't find a file called \(q).")

        case .play(let query, let service):
            let s = service ?? settings.effectiveMusicService
            trace("play \(query) on \(s)")
            if s != .youtube, let blocked = await mayControl(s == .appleMusic ? [.music] : [.spotify]) { return blocked }
            return await play(query, on: s)

        case .nowPlaying:
            if let blocked = await mayControl([.spotify, .music]) { return blocked }
            return .info(await AppleMusic.nowPlaying().map { "This is \($0)." } ?? "Nothing is playing in Spotify or Music.")

        case .player(let c):
            if let blocked = await mayControl([.spotify, .music]) { return blocked }
            return await Player.control(c, preferred: settings.effectiveMusicService).map { .info($0) } ?? .done

        case .media(let key, _):
            Keyboard.media(key)
            return .done

        case .setVolume(let v):
            await Script.run("set volume output volume \(v)")
            return .done

        case .setBrightness(let v):
            await SystemControl.setBrightness(v)
            return .done

        case .shell(let path, let args, _):
            SystemControl.run(path, args)
            return .done

        case .appleScript(let src, _):
            return await Script.run(src) != nil ? .done : .failed("That didn't work. Allow Vox to control System Events in Settings.")

        case .wifi(let on):
            SystemControl.run("/usr/sbin/networksetup", ["-setairportpower", Self.wifiDevice(), on ? "on" : "off"])
            return .info("Wi-Fi \(on ? "on" : "off").")

        case .power(let p):
            let q = switch p {
                case .shutdown: "Shut down your Mac?"
                case .restart: "Restart your Mac?"
                case .logout: "Log out?"
                case .sleep: "Put your Mac to sleep?"
            }
            return confirm(q) { await SystemControl.perform(p); return .done }

        case .emptyTrash:
            return confirm("Empty the Trash? This can't be undone.") {
                await Script.run("tell application \"Finder\" to empty trash", timeout: 60) != nil
                    ? .info("Trash emptied.") : .failed("I couldn't empty the Trash.")
            }

        case .storage:
            return .info(SystemControl.storage())

        case .runShortcut(let name):
            let ok = await Task.detached { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["run", name]
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }.value
            return ok ? .done : .failed("I couldn't run a shortcut called \(name).")

        case .timer(let seconds, let label):
            return .info(Schedule.shared.addTimer(seconds: seconds, label: label))
        case .alarm(let text):
            return .info(Schedule.shared.addAlarm(text))
        case .cancelTimers:
            return .info(Schedule.shared.cancelAll())
        case .timeLeft:
            return .info(Schedule.shared.timeLeft())
        case .reminder(let text, let seconds):
            return .info(await Schedule.shared.addReminder(text, inSeconds: seconds))
        case .addEvent(let text):
            return .info(await Schedule.shared.addEvent(text))
        case .agenda(let day):
            return .info(await Schedule.shared.agenda(dayOffset: day))
        case .nextEvent:
            return .info(await Schedule.shared.nextEvent())

        case .makeNote(let text):
            let ok = await Script.run("""
                tell application "Notes"
                    make new note with properties {body:"\(Messaging.escape(text))"}
                end tell
                """, timeout: 15) != nil
            return ok ? .info("Noted.") : .failed("I couldn't create the note. Allow Vox to control Notes in System Settings.")

        case .weather(let place, let day, let rain):
            return .info(await Weather.report(place: place, dayOffset: day, askingRain: rain))

        case .convert(let c):
            if c.isCurrency { return .info(await Calc.convertCurrency(c)) }
            return Calc.convertUnits(c).map { .info($0) } ?? .failed("I can't convert those units.")

        case .say(let s):
            switch s {
            case "__coin": return .info(Bool.random() ? "Heads." : "Tails.")
            case "__dice": return .info("You rolled a \(Int.random(in: 1...6)).")
            default: return .info(s)
            }

        case .ask(let question):
            return .info(await brain.answer(question))

        case .speakInfo(let info):
            switch info {
            case .time: return .info("It's \(Date().formatted(date: .omitted, time: .shortened)).")
            case .date: return .info("Today is \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year())).")
            case .battery: return .info(Self.batteryString())
            }

        case .directions(let place):
            return openMaps(["daddr": place, "dirflg": "d"])
        case .mapSearch(let q):
            return openMaps(["q": q])

        case .text(let op, let source):
            return await textTool(op, source)

        case .message(let to, let body, let via):
            return await message(to: to, body: body, via: via)

        case .email(let to, let subject, let body):
            return await email(to: to, subject: subject, body: body)

        case .beginDictation:
            if let opened, Self.newDocApps.contains(opened) {
                Keyboard.press(Key.Combo(key: Key.code["n"]!, mods: .cmd))
                try? await Task.sleep(for: .milliseconds(350))
            }
            return .done
        case .type(let text):
            Keyboard.type(text)
            return .done
        case .backspace(let n):
            Keyboard.backspace(n)
            return .done

        case .confirm(let yes):
            // A stray "yeah" with no question pending does nothing (it used to press Return in the front app).
            guard let p = pending, p.expires > Date() else { pending = nil; return .done }
            pending = nil
            return yes ? await p.run() : .info("OK, I won't.")

        case .send:
            if let p = pending, p.expires > Date() { pending = nil; return await p.run() }
            pending = nil
            // "send it" with nothing to confirm: send what's typed in the current app.
            Keyboard.press(Key.Combo(key: Key.code["return"]!, mods: []))
            return .done

        case .stopListening:
            pending = nil
            onStopListening()
            return .done
        }
    }

    // MARK: Media

    /// macOS must allow Vox to script Spotify and Music. If it doesn't (or is still waiting for an answer, which
    /// it can't get while the screen is locked), say how to fix it instead of hanging.
    private func mayControl(_ apps: [Player.Target]) async -> Outcome? {
        for t in apps {
            let (id, name) = t == .spotify ? (Spotify.bundleID, "Spotify") : ("com.apple.Music", "Music")
            if Spotify.isInstalled || t == .music, !(await Script.allowed(id)) {
                return .failed("Allow Vox to control \(name) in System Settings, Privacy and Security, Automation.")
            }
        }
        return nil
    }

    private func play(_ query: String, on service: Settings.MusicService) async -> Outcome {
        switch service {
        case .youtube:
            await Player.pauseApps()      // one thing playing at a time
            let target = browser ?? Self.defaultBrowser()
            let reuse = lastYouTubeHome.map { -$0.timeIntervalSinceNow < 15 } ?? false
            lastYouTubeHome = nil
            if let title = await YouTube.play(query, in: target, reuseTab: reuse) { Player.last = .web; return .info("Playing \(title).") }
            return .failed("I couldn't find a video for \(query).")
        case .appleMusic, .spotify, .auto:
            let asked = Self.songQuery(query)
            var title = asked
            if service == .appleMusic {
                // The library search needs the exact title, so correct it first.
                title = await brain.correctSong(asked)
                if let playing = await AppleMusic.play(title) { Player.last = .music; return .info("Playing \(playing).") }
            }
            if Spotify.isInstalled {
                // Search with what was heard first; only wake the language model (a burst of several watts)
                // when nothing found is titled like it, e.g. a Hindi title heard as English words.
                var found = await Spotify.search(title)
                trace("found \(found.count), confident: \(Spotify.confident(found, for: title))")
                if !Spotify.confident(found, for: title), title == asked {
                    let fixed = await brain.correctSong(asked)
                    trace("corrected to \(fixed)")
                    if fixed.lowercased() != asked.lowercased() {
                        title = fixed
                        let again = await Spotify.search(fixed)
                        if !again.isEmpty { found = again }
                    }
                }
                if let playing = await Spotify.play(candidates: found, query: title) { Player.last = .spotify; return .info("Playing \(playing).") }
            }
            // Not found (or Spotify skipped it in this region): play it on YouTube rather than stop at a search page.
            await Player.pauseApps()
            let target = browser ?? Self.defaultBrowser()
            if let video = await YouTube.play(title, in: target) { Player.last = .web; return .info("Playing \(video) on YouTube.") }
            return .failed("I couldn't find \(title) anywhere.")
        }
    }

    /// "the song kesariya", "some arijit singh songs" -> "kesariya", "arijit singh".
    static func songQuery(_ q: String) -> String {
        var w = q.split(separator: " ").map(String.init)
        while let f = w.first?.lowercased(), w.count > 1, ["some", "the", "a", "song", "songs", "track", "me", "any"].contains(f) { w.removeFirst() }
        while let l = w.last?.lowercased(), w.count > 1, ["song", "songs", "track", "gaana", "gana", "please"].contains(l) { w.removeLast() }
        return w.joined(separator: " ")
    }

    // MARK: Text tools

    private func textTool(_ op: TextTools.Operation, _ source: Action.TextSource) async -> Outcome {
        let text: String?
        switch source {
        case .selection: text = await TextTools.selectedText()
        case .page: text = await TextTools.pageText()
        case .clipboard: text = TextTools.clipboard()
        }
        guard let text else {
            return .failed(source == .clipboard ? "Your clipboard is empty." : "Select some text first.")
        }
        if op == .read { return .info(String(text.prefix(4000))) }
        let result = await brain.transform(String(text.prefix(6000)), instruction: op.instruction)
        guard !result.isEmpty else { return .failed("I couldn't do that with this text.") }
        if op.replaces, source == .selection {
            await TextTools.replaceSelection(with: result)
            return .done
        }
        return .info(result)
    }

    // MARK: Messaging

    private func message(to: String, body: String, via: Messaging.Channel) async -> Outcome {
        guard let person = await Messaging.find(to) else {
            return .failed("I couldn't find \(to) in your contacts.")
        }
        switch via {
        case .whatsApp:
            guard let phone = person.phones.first else { return .failed("\(person.name) has no phone number for WhatsApp.") }
            guard Messaging.openWhatsApp(body, phone: phone) else { return .failed("I couldn't open WhatsApp.") }
            return confirm("Send \"\(body)\" to \(person.name) on WhatsApp?") {
                await self.waitForFront("net.whatsapp.WhatsApp")
                Keyboard.press(Key.Combo(key: Key.code["return"]!, mods: []))
                return .info("Sent.")
            }
        case .iMessage, .email:
            guard let handle = person.phones.first ?? person.emails.first else {
                return .failed("\(person.name) has no phone number or email.")
            }
            return confirm("Send \"\(body)\" to \(person.name)?") {
                await Messaging.sendIMessage(body, to: handle) ? .info("Sent.") : .failed("Messages couldn't send that. Is iMessage set up on this Mac?")
            }
        }
    }

    private func email(to: String?, subject: String?, body: String?) async -> Outcome {
        var address: String?
        var name = to
        if let to {
            if to.contains("@") { address = to.replacingOccurrences(of: " at ", with: "@").replacingOccurrences(of: " ", with: "") }
            else if let p = await Messaging.find(to) {
                address = p.emails.first
                name = p.name
                if address == nil { return .failed("\(p.name) has no email address.") }
            } else { return .failed("I couldn't find \(to) in your contacts.") }
        }
        guard Messaging.composeEmail(to: address, subject: subject, body: body) else { return .failed("I couldn't open Mail.") }
        let mailIsDefault = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:x@y.z")!)?.lastPathComponent == "Mail.app"
        guard body != nil, address != nil, mailIsDefault else { return .info("Your draft is ready.") }
        return confirm("Send the email to \(name ?? "them")?") {
            await self.waitForFront("com.apple.mail")
            Keyboard.press(Key.Combo(key: Key.code["d"]!, mods: [.cmd, .shift]))
            return .info("Email sent.")
        }
    }

    // MARK: Helpers

    private func openMaps(_ query: [String: String]) -> Outcome {
        var c = URLComponents(string: "maps://")!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url.map { NSWorkspace.shared.open($0) } == true ? .done : .failed("I couldn't open Maps.")
    }

    private func open(_ app: AppIndex.App) async -> Bool {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        guard let running = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) else { return false }
        let id = running.bundleIdentifier ?? ""
        if Self.browserIDs.contains(id) { browser = app }
        justOpened = id
        await waitForFront(id)
        return true
    }

    /// Short, bounded wait for an app to take focus; cheap 50 ms polls, at most 3 s.
    private func waitForFront(_ bundleID: String) async {
        for _ in 0..<60 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                try? await Task.sleep(for: .milliseconds(60))
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func defaultBrowser() -> AppIndex.App? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return AppIndex.App(name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    // MARK: Speech

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = settings.voice
        u.rate = Float(settings.speechRate)
        speech.stopSpeaking(at: .immediate)
        // Mute the mic before the first syllable (the delegate's didStart arrives too late), so Vox never
        // hears itself say "Wi-Fi off" and act on it.
        speaking = u
        onSpeaking(true)
        speech.speak(u)
    }

    func stopSpeaking() {
        speaking = nil
        speech.stopSpeaking(at: .immediate)
        onSpeaking(false)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.finished(u) } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.finished(u) } }

    /// Unmute once the room has stopped echoing the last word, unless a newer utterance has started.
    private func finished(_ u: AVSpeechUtterance) {
        guard speaking === u else { return }
        speaking = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, speaking == nil else { return }
            onSpeaking(false)
        }
    }

    /// The Wi-Fi interface name (usually en0, but not always).
    private static func wifiDevice() -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallhardwareports"]
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = out.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains("Wi-Fi") }), i + 1 < lines.count,
           let dev = lines[i + 1].components(separatedBy: "Device: ").last { return dev.trimmingCharacters(in: .whitespaces) }
        return "en0"
    }

    static func batteryString() -> String {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let cap = d[kIOPSCurrentCapacityKey] as? Int {
                let charging = (d[kIOPSIsChargingKey] as? Bool) == true ? ", and charging" : ""
                return "Your battery is at \(cap) percent\(charging)."
            }
        }
        return "This Mac has no battery."
    }
}
