import AppKit
import ApplicationServices
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let settings = Settings.shared
    private let listener = Listener()
    private let stream = CommandStream()
    private let fallbackStream = CommandStream()
    private let brain = Brain()
    private lazy var executor = Executor(brain: brain)
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var hotkey: Hotkey?
    private var ready = false
    private var pressedAt: Date?
    private var startedByPress = false

    // Hands-free ("Hey Vox") state. The transcript is shared between waiting and commanding;
    // `wakeIndex` is the word where the current command starts.
    private var awake = false
    private var weakWake = false
    private var wakeIndex = 0
    private var lastFinal = "", lastVolatile = ""
    private var screenAsleep = false
    private var settleWork: DispatchWorkItem?
    /// Hands-free restarts after the mic or recognizer failed; backs off so a missing mic costs nothing.
    private var restartWork: DispatchWorkItem?
    private var restartAttempts = 0
    private var handsFreeSince: Date?

    private var shouldRunHandsFree: Bool { settings.handsFree && ready && !screenAsleep }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        wire()
        hotkey = Hotkey(down: { [weak self] in Task { @MainActor in self?.hotkeyDown() } },
                        up: { [weak self] in Task { @MainActor in self?.hotkeyUp() } })

        let ws = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenAsleep = asleep; self?.syncHandsFree() }
            }
        }
        // After the Mac sleeps, the audio engine can come back silently dead; start it fresh.
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartHandsFree() }
        }
        UNUserNotificationCenter.current().delegate = self
        Schedule.shared.restore()

        if !settings.onboarded {
            SettingsWindow.shared.show(.welcome)
            settings.onboarded = true
        } else if !AXIsProcessTrusted() {
            SettingsWindow.shared.show(.permissions)
        }

        Task {
            do {
                try await listener.prepare(contextNames: Parser.vocabulary + AppIndex.shared.contextualNames)
                ready = true
                syncHandsFree()
            } catch {
                NSLog("Vox: speech setup failed: \(error)")
                alert("Speech setup failed", "\(error.localizedDescription)\n\nCheck that your language is supported for on-device dictation.")
            }
        }
    }

    private func wire() {
        listener.voiceProcessing = settings.echoCancellation
        listener.preferBuiltInMic = settings.builtInMic
        settings.onChange = { [weak self] in
            guard let self else { return }
            if listener.voiceProcessing != settings.echoCancellation || listener.preferBuiltInMic != settings.builtInMic {
                listener.voiceProcessing = settings.echoCancellation
                listener.preferBuiltInMic = settings.builtInMic
                restartHandsFree()
            }
            syncHandsFree()
        }
        SettingsWindow.shared.speak = { [weak self] in self?.executor.speak($0) }

        executor.onDone = { [weak self] action, outcome in
            guard let self else { return }
            trace("did \(action) → \(outcome)")
            hud.did(action, outcome)
            // One command, then back to sleep: a short pause ends the session unless you're dictating
            // or Vox is waiting for a yes/no.
            if case .asking = outcome { return }
            switch action {
            case .beginDictation, .type, .backspace: listener.setTimeout(2.5)
            default: listener.setTimeout(stream.isDictating ? 2.5 : 1.0)
            }
        }
        executor.onPrompt = { [weak self] _ in self?.listenForAnswer() }
        executor.onStopListening = { [weak self] in self?.endCommand() }
        executor.onSpeaking = { [weak self] in self?.listener.muted = $0 }

        Schedule.shared.onFire = { [weak self] alarm in
            guard let self else { return }
            let text = alarm.isTimer ? "Your \(alarm.label) timer is done." : "It's \(alarm.label). This is your alarm."
            hud.answer("⏰ " + text)
            for i in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { NSSound(named: "Glass")?.play() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { self.executor.speak(text) }
        }

        hud.onVisibilityChange = { [weak self] in self?.listener.reportsLevel = $0 }
        listener.onLevel = { [weak self] in self?.hud.level($0) }
        stream.emit = { [weak self] action in
            guard let self else { return }
            // A weak wake ("he works…" at the start of a sentence) may be someone else talking: run clear
            // commands, but never answer an open question out loud.
            if weakWake, case .ask = action { hud.note("Say “Hey Vox” to ask a question"); return }
            executor.enqueue(action)
        }
        fallbackStream.emit = { [weak self] in self?.executor.enqueue($0) }
        stream.onUnparsed = { [weak self] in self?.askBrain($0) }
        fallbackStream.onUnparsed = { [weak self] text in
            guard let self else { return }
            hud.note("Didn't understand: \(text)")
            if settings.feedback != .quiet { executor.speak("Sorry, I didn't get that.") }
        }

        listener.onText = { [weak self] in self?.heard(final: $0, volatile: $1) }
        listener.onIdle = { [weak self] in self?.idle() }
        listener.onEnded = { [weak self] in self?.micClosed(final: $0) }
        listener.onConfigChange = { [weak self] in
            guard let self else { return }
            // Hands-free: start again on the new device. A ⌥Space session: end it cleanly rather than
            // leave it listening to a mic that no longer delivers audio.
            if listener.continuous { restartHandsFree() } else { Task { await self.listener.stop() } }
        }
        listener.chooseFinal = { best, alternatives in
            // Keep the recognizer's top guess unless an alternative is clearly more command-like.
            let top = Parser.score(best)
            return alternatives.map { ($0, Parser.score($0)) }.filter { $0.1 > top + 1 }.max { $0.1 < $1.1 }?.0 ?? best
        }
    }

    // MARK: Transcript

    private func heard(final: String, volatile: String) {
        lastFinal = final; lastVolatile = volatile
        if listener.continuous && !awake {
            let words = (final + " " + volatile).split(whereSeparator: \.isWhitespace).map(String.init)
            guard let m = Wake.find(raw: words) else {
                if final.split(whereSeparator: \.isWhitespace).count > 24 { listener.trimTranscript(keepingLast: 4) }
                return
            }
            wake(at: m.next)
            weakWake = !m.strong
            trace("woke (\(m.strong ? "strong" : "weak")) on: \(words.joined(separator: " "))")
        }
        let (f, v) = listener.continuous ? afterWake(final, volatile) : (final, volatile)
        hud.text(final: f, volatile: v)
        stream.update(final: f, volatile: v)
        // The command has begun: the thinking time after "Hey Vox" is over, so a pause now ends it.
        if awake || !listener.continuous, !(f + v).isEmpty { listener.grace(0) }
        if stream.holding { listener.setTimeout(1.2) }

        // If the recognizer's guess stays the same for a moment, act on it now rather than waiting for it
        // to commit the words.
        settleWork?.cancel()
        guard !v.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.stream.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The part of the transcript after "Hey Vox", split back into its final and volatile parts.
    private func afterWake(_ final: String, _ volatile: String) -> (String, String) {
        let f = final.split(whereSeparator: \.isWhitespace), v = volatile.split(whereSeparator: \.isWhitespace)
        return (f.dropFirst(min(wakeIndex, f.count)).joined(separator: " "),
                v.dropFirst(max(0, wakeIndex - f.count)).joined(separator: " "))
    }

    private func wake(at index: Int, chime: Bool = true) {
        awake = true
        weakWake = false
        wakeIndex = index
        listener.gateBypassed = true
        stream.reset()
        executor.stopSpeaking()
        listener.grace(6)          // give time to think of the command after "Hey Vox"
        hud.show()
        hud.setListening(true)
        if chime, settings.soundEffects { NSSound(named: "Tink")?.play() }
        refreshIcon()
    }

    /// Vox asked a yes/no question: keep (or start) listening for the answer without a wake word.
    private func listenForAnswer() {
        if listener.running && listener.continuous {
            if !awake { wake(at: (lastFinal + " " + lastVolatile).split(whereSeparator: \.isWhitespace).count, chime: false) }
            listener.grace(9)
            listener.setTimeout(3)
        } else if listener.running {
            listener.grace(9)
            listener.setTimeout(3)
        } else {
            startSession(chime: false)
            listener.grace(9)
        }
    }

    /// Continuous mode: speech paused long enough that the command (if any) is over.
    private func idle() {
        if awake { endCommand() } else { clearTranscript() }
    }

    private func endCommand() {
        settleWork?.cancel()
        trace("command over: \(lastFinal) | \(lastVolatile)")
        guard listener.continuous else { Task { await listener.stop() }; return }
        guard awake else { return }
        let (f, v) = afterWake(lastFinal, lastVolatile)
        stream.finish(final: f + " " + v)
        awake = false
        listener.gateBypassed = false
        clearTranscript()
        if settings.soundEffects { NSSound(named: "Pop")?.play() }
        hud.setListening(false)
        hud.hide()
        refreshIcon()
    }

    private func clearTranscript() {
        listener.resetTranscript()
        lastFinal = ""; lastVolatile = ""; wakeIndex = 0
    }

    private func micClosed(final: String) {
        listener.gateBypassed = false
        if awake {
            // The mic closed mid-command (device change, recognizer error): still run what was said.
            let (f, v) = afterWake(lastFinal, lastVolatile)
            stream.finish(final: f + " " + v)
            awake = false
        } else if !listener.continuous {
            stream.finish(final: final)
            if settings.soundEffects { NSSound(named: "Pop")?.play() }
        }
        hud.setListening(false)
        hud.hide()
        clearTranscript()
        refreshIcon()
        // A hotkey session just ended, or hands-free stopped unexpectedly: go back to waiting for "Hey Vox".
        if !listener.continuous { syncHandsFree() } else if shouldRunHandsFree, !listener.running {
            // Only a listener that ran steadily for a while earns a quick restart; one that keeps dying right
            // after starting backs off, so a persistent fault can't keep the mic and recognizer cycling.
            if let t = handsFreeSince, Date().timeIntervalSince(t) > 30 { restartAttempts = 0 }
            scheduleRestart()
        }
    }

    private func askBrain(_ text: String) {
        guard !Parser.normalize(text).isEmpty, !weakWake else { return }
        // One unknown word is a misheard fragment (often left over after a command); don't apologize for it.
        // Likewise a word or two left over after a command that already ran ("restart… my mac").
        let n = text.split(whereSeparator: \.isWhitespace).count
        guard n >= 2, n > 2 || stream.ran == 0 else { hud.note("Didn't catch: \(text)"); return }
        guard brain.isAvailable else {
            hud.note("Didn't understand: \(text)")
            executor.speak("Sorry, I didn't get that.")
            return
        }
        hud.thinking()
        Task {
            let commands = await brain.rewrite(text)
            if commands.isEmpty {
                hud.note("Didn't understand: \(text)")
                if settings.feedback != .quiet { executor.speak("Sorry, I didn't get that.") }
            }
            for c in commands { fallbackStream.runOnce(c) }
        }
    }

    // MARK: Hotkey

    private func hotkeyDown() {
        pressedAt = Date()
        if listener.running && listener.continuous {
            if awake { startedByPress = false; endCommand() } else {
                startedByPress = true
                wake(at: (lastFinal + " " + lastVolatile).split(whereSeparator: \.isWhitespace).count)
            }
        } else if listener.running {
            startedByPress = false
            Task { await listener.stop() }
        } else {
            startedByPress = true
            startSession()
        }
    }

    /// Held longer than a tap: push-to-talk, so finish on release.
    private func hotkeyUp() {
        guard startedByPress, let t = pressedAt, Date().timeIntervalSince(t) > 0.4 else { return }
        startedByPress = false
        if listener.continuous { endCommand() } else { Task { await listener.stop() } }
    }

    // MARK: Listener lifecycle

    /// Start or stop the always-on listener to match settings and screen state.
    private func syncHandsFree() {
        refreshIcon()
        if shouldRunHandsFree && !listener.running {
            restartWork?.cancel(); restartWork = nil
            Task {
                do {
                    try await listener.start(continuous: true)
                    handsFreeSince = Date()
                } catch is CancellationError {
                } catch {
                    NSLog("Vox: hands-free start failed: \(error)")
                    scheduleRestart()
                }
                refreshIcon()
            }
        } else if !shouldRunHandsFree && listener.running && listener.continuous {
            Task { await listener.stop() }
        }
    }

    /// Try hands-free again after a failure: 1, 2, 4 … 60 s apart, so a missing mic or a denied permission
    /// costs almost nothing, while a brief glitch (headphones reconnecting) recovers within a second.
    private func scheduleRestart() {
        guard restartWork == nil else { return }
        let delay = min(60, pow(2, Double(restartAttempts)))
        restartAttempts += 1
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            restartWork = nil
            syncHandsFree()
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func restartHandsFree() {
        guard listener.running && listener.continuous else { syncHandsFree(); return }
        Task {
            await listener.stop()
            try? await Task.sleep(for: .milliseconds(300))
            syncHandsFree()
        }
    }

    private func startSession(chime: Bool = true) {
        guard ready else { NSSound.beep(); return }
        executor.stopSpeaking()
        stream.reset()
        hud.show()
        hud.setListening(true)
        if chime, settings.soundEffects { NSSound(named: "Tink")?.play() }
        Task {
            do { try await listener.start() } catch is CancellationError {
                // Tapped again while the mic was still opening: just close the popup.
                hud.setListening(false)
                hud.hide()
            } catch {
                NSLog("Vox: start failed: \(error)")
                hud.note("Microphone unavailable. Check Vox Settings → Permissions.")
                hud.setListening(false)
                hud.hide(after: 3)
            }
            refreshIcon()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if !ready { status = "Starting…" }
        else if awake || (listener.running && !listener.continuous) { status = "Listening…" }
        else if listener.running { status = "Waiting for “Hey Vox”" }
        else if settings.handsFree && screenAsleep { status = "Paused while the screen is off" }
        else { status = "Hold ⌥ Space to talk" }
        let head = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        head.isEnabled = false

        menu.addItem(item("Talk to Vox", #selector(talk), " ", [.option]))
        let hf = item("Listen for “Hey Vox”", #selector(toggleHandsFree))
        hf.state = settings.handsFree ? .on : .off
        menu.addItem(hf)

        let alarms = Schedule.shared.alarms.sorted { $0.fire < $1.fire }
        if !alarms.isEmpty {
            menu.addItem(.separator())
            for a in alarms {
                let when = a.isTimer ? "\(a.label) timer · ends \(a.fire.formatted(date: .omitted, time: .shortened))"
                    : "Alarm · \(Schedule.spoken(a.fire))"
                let sub = NSMenu()
                let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelAlarm(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = a.id
                sub.addItem(cancel)
                let it = menu.addItem(withTitle: when, action: nil, keyEquivalent: "")
                it.image = NSImage(systemSymbolName: a.isTimer ? "timer" : "alarm", accessibilityDescription: nil)
                it.submenu = sub
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("What Can I Say?", #selector(openCommands)))
        menu.addItem(item(!Spotify.Credentials.saved ? "Connect Spotify…" : "Spotify Connected ✓", #selector(connectSpotify)))
        if !brain.isAvailable {
            let m = menu.addItem(withTitle: "Turn on Apple Intelligence for smarter answers", action: nil, keyEquivalent: "")
            m.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Vox", #selector(NSApplication.terminate(_:)), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.target = action == #selector(NSApplication.terminate(_:)) ? nil : self
        return i
    }

    @objc private func talk() { hotkeyDown(); startedByPress = false }
    @objc private func toggleHandsFree() { settings.handsFree.toggle() }
    @objc private func openSettings() { SettingsWindow.shared.show(.general) }
    @objc private func openCommands() { SettingsWindow.shared.show(.commands) }
    @objc private func cancelAlarm(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { Schedule.shared.cancel(id) }
    }

    /// Spotify Web API app credentials, used only to look up track IDs for "play …".
    @objc private func connectSpotify() {
        let a = NSAlert()
        a.messageText = "Connect Spotify"
        a.informativeText = """
            Optional: makes “play …” find the exact song every time.
            1. Open developer.spotify.com/dashboard and log in.
            2. Create app → any name, Redirect URI: http://127.0.0.1:8888, tick “Web API”.
            3. Open the app’s Settings and paste its Client ID and Client Secret here.
            They are stored in your Keychain and only used to search.
            """
        let id = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        id.placeholderString = "Client ID"
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        secret.placeholderString = "Client Secret"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(id); box.addSubview(secret)
        a.accessoryView = box
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Open Dashboard")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        a.window.initialFirstResponder = id
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let i = id.stringValue.trimmingCharacters(in: .whitespaces), s = secret.stringValue.trimmingCharacters(in: .whitespaces)
            Task {
                if await Spotify.Credentials.verify(id: i, secret: s) {
                    Spotify.Credentials.save(id: i, secret: s)
                    alert("Spotify connected", "Say “Hey Vox, play Kesariya”.")
                } else {
                    alert("Spotify didn’t accept those", "Check the Client ID and Secret and try again.")
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
        default: break
        }
    }

    private func refreshIcon() {
        let symbol: String
        if awake || (listener.running && !listener.continuous) { symbol = "waveform.circle.fill" }
        else if listener.running { symbol = "ear" }             // waiting for "Hey Vox"
        else { symbol = "waveform.circle" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Vox")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // Show timer/alarm notifications even though Vox is technically the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

/// Developer trace for live tests: launch with VOX_LOG=/path to record wakes, commands and outcomes.
@MainActor func trace(_ s: String) {
    guard let p = ProcessInfo.processInfo.environment["VOX_LOG"] else { return }
    if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: p) else { return }
    h.seekToEndOfFile()
    h.write(Data((Date().formatted(.dateTime.hour().minute().second()) + "  " + s + "\n").utf8))
    try? h.close()
}
