import AppKit

/// Play, pause, next and previous, sent to whatever is actually playing.
///
/// The hardware play key is not used when nothing is playing: macOS then launches Apple Music, which is
/// never what the user meant. Spotify and Music are controlled directly by AppleScript (only when they are
/// already running, since scripting an app launches it). A playing browser tab gets the media key.
@MainActor
enum Player {
    enum Command {
        case toggle, play, pause, next, previous
        var label: String {
            switch self {
            case .toggle: return "Play/Pause"
            case .play: return "Resume"
            case .pause: return "Pause"
            case .next: return "Next track"
            case .previous: return "Previous track"
            }
        }
        /// AppleScript verb, the same in Spotify and Music.
        var verb: String {
            switch self {
            case .toggle: return "playpause"
            case .play: return "play"
            case .pause: return "pause"
            case .next: return "next track"
            case .previous: return "previous track"
            }
        }
        /// NX media key for browsers.
        var key: Int32 { self == .next ? 17 : self == .previous ? 18 : 16 }
    }

    enum Target { case spotify, music, web }

    /// Where Vox last started playback, so "resume" goes back there.
    static var last: Target?
    /// When Vox last paused a browser. The media key toggles, and a browser can keep its audio stream (which is
    /// how playing is detected) open for a few seconds after pausing, so a second "pause" mustn't resume it.
    private static var pausedWebAt: Date?

    /// Returns a message to say when there was nothing to control, or nil when it worked.
    static func control(_ c: Command, preferred: Settings.MusicService) async -> String? {
        let spotify = running(Spotify.bundleID), music = running("com.apple.Music")
        // Browsers also hold the media assertion for silent autoplay videos, so apps come first.
        let playing: Target? = await state("Spotify") == "playing" ? .spotify : await state("Music") == "playing" ? .music
            : MediaState.webMediaPlaying ? .web : nil
        var resume: Target? {
            if let last, last != .web || Executor.browserIDs.contains(where: running) { return last }
            if spotify { return .spotify }
            if music { return .music }
            if playing == .web { return .web }
            if preferred == .appleMusic { return .music }
            if preferred != .youtube, Spotify.isInstalled { return .spotify }
            return nil
        }
        let target: Target, cmd: Command
        switch c {
        case .pause:
            guard let playing else { return nil }
            (target, cmd) = (playing, .pause)
        case .toggle:
            // A browser "playing" may be a silent autoplay video, so a paused music app wins.
            if let playing, playing != .web || resume == .web || resume == nil { (target, cmd) = (playing, .pause) }
            else if let resume { (target, cmd) = (resume, .play) }
            else { return "Nothing is playing. Tell me what to play." }
        case .play:
            if playing == .spotify || playing == .music { return nil }
            guard let resume else { return "Nothing is playing. Tell me what to play." }
            if resume == .web && playing == .web { return nil }
            (target, cmd) = (resume, .play)
        case .next, .previous:
            guard let t = playing ?? resume else { return "Nothing is playing." }
            (target, cmd) = (t, c)
        }

        switch target {
        case .web:
            if cmd == .pause, let t = pausedWebAt, -t.timeIntervalSinceNow < 10 { return nil }
            pausedWebAt = cmd == .pause ? Date() : nil
            Keyboard.media(cmd.key)
            // The key goes to macOS's "now playing" app, which may be a paused Spotify rather than the browser.
            if cmd == .pause {
                try? await Task.sleep(for: .milliseconds(300))
                await pauseApps()
            }
        case .spotify, .music:
            let app = target == .spotify ? "Spotify" : "Music"
            let id = target == .spotify ? Spotify.bundleID : "com.apple.Music"
            if !running(id) {
                guard await launch(id, app: app) else { return "\(app) isn't installed." }
            }
            if target == .spotify, cmd == .next { await Spotify.next() } else { await Script.run("tell application \"\(app)\" to \(cmd.verb)") }
            if cmd != .pause {
                // Starting playback can take a moment, longer right after launch.
                var ok = false
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if await state(app) == "playing" { ok = true; break }
                }
                if !ok { return "\(app) has nothing queued. Tell me what to play." }
            }
        }
        last = target
        return nil
    }

    /// Pause Spotify and Music if they're playing (before something else starts, so two never play at once).
    static func pauseApps() async {
        for app in ["Spotify", "Music"] where await state(app) == "playing" {
            await Script.run("tell application \"\(app)\" to pause")
        }
    }

    /// Launch an app in the background and wait until it answers AppleScript (a cold Spotify can take
    /// several seconds on battery; scripting it before then fails or is ignored).
    static func launch(_ bundleID: String, app: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        for _ in 0..<40 {
            if await Script.run("tell application \"\(app)\" to return player state as text", timeout: 2) != nil {
                try? await Task.sleep(for: .milliseconds(300))   // answering isn't quite ready to play
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    static func running(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// "playing", "paused" or "stopped"; empty if the app isn't running.
    static func state(_ app: String) async -> String {
        guard running(app == "Spotify" ? Spotify.bundleID : "com.apple.Music") else { return "" }
        return await Script.run("tell application \"\(app)\" to return player state as text", timeout: 3) ?? ""
    }
}
