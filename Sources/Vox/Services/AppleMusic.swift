import AppKit

/// Apple Music: plays from the user's library by AppleScript. Apple offers no way to start catalog playback
/// without a developer token, so songs not in the library are played elsewhere by the executor.
@MainActor
enum AppleMusic {
    static func play(_ query: String) async -> String? {
        let q = query.replacingOccurrences(of: "\"", with: "")
        let script = """
            tell application "Music"
                set hits to (search playlist "Library" for "\(q)")
                if hits is {} then return ""
                play item 1 of hits
                return (name of current track) & " — " & (artist of current track)
            end tell
            """
        return await Script.run(script, timeout: 10).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "What's playing?" across Spotify and Music.
    static func nowPlaying() async -> String? {
        for (app, id) in [("Spotify", Spotify.bundleID), ("Music", "com.apple.Music")] {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { continue }
            let script = """
                tell application "\(app)"
                    if player state is playing then return (name of current track) & " by " & (artist of current track)
                end tell
                return ""
                """
            if let r = await Script.run(script, timeout: 3), !r.isEmpty { return r }
        }
        return nil
    }
}
