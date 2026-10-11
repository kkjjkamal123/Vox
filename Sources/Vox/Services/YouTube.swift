import AppKit
import IOKit.pwr_mgt

/// "Play X on YouTube" plays a video instead of showing search results: the search page is fetched,
/// the video IDs are read out of its embedded data, and the chosen video is opened directly.
enum YouTube {
    struct Video { let id: String; let title: String }

    /// Parses "random ltt video", "the latest mkbhd video", "a video of cats" into a query plus intent.
    struct Request {
        var query: String
        var random = false
        var latest = false

        init(_ spoken: String) {
            var words = spoken.lowercased().split(separator: " ").map(String.init)
            if words.contains(where: { ["random", "any", "some", "surprise"].contains($0) }) { random = true }
            if words.contains(where: { ["latest", "newest", "new", "recent", "last"].contains($0) }) { latest = true }
            let noise: Set<String> = ["random", "any", "some", "a", "an", "the", "latest", "newest", "new", "recent", "last",
                                      "video", "videos", "of", "clip", "on", "youtube", "surprise", "me", "one"]
            words.removeAll { noise.contains($0) }
            query = words.joined(separator: " ")
            if query.isEmpty { query = "trending"; random = true }
        }
    }

    static func search(_ query: String, latest: Bool) async -> [Video] {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [.init(name: "search_query", value: query)]
        if latest { c.queryItems?.append(.init(name: "sp", value: "CAI=")) }     // sort by upload date
        var req = URLRequest(url: c.url!, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8) else { return [] }
        var videos: [Video] = []
        var seen = Set<String>()
        for m in html.matches(of: #/"videoRenderer":\{"videoId":"([\w-]{11})".{0,1500}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"/#) {
            let id = String(m.1)
            guard seen.insert(id).inserted else { continue }
            let title = String(m.2).replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "\\\"", with: "\"")
            videos.append(Video(id: id, title: title))
            if videos.count >= 12 { break }
        }
        return videos
    }

    /// Returns the title of the video that was opened, or nil if nothing was found.
    @MainActor
    static func play(_ spoken: String, in browser: AppIndex.App?, reuseTab: Bool = false) async -> String? {
        let req = Request(spoken)
        let results = await search(req.query, latest: req.latest)
        guard let video = req.random ? results.prefix(10).randomElement() : results.first else { return nil }
        let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)")!
        if reuseTab, let front = NSWorkspace.shared.frontmostApplication, let browser,
           front.bundleIdentifier == Bundle(url: browser.url)?.bundleIdentifier {
            // "open YouTube and play …": load the video in the YouTube tab that was just opened, through the
            // address bar. (Closing that tab instead would close one of yours if a different tab were in front.)
            Keyboard.press(Key.Combo(key: Key.code["l"]!, mods: .cmd))
            try? await Task.sleep(for: .milliseconds(120))
            Keyboard.type(url.absoluteString)
            try? await Task.sleep(for: .milliseconds(60))
            Keyboard.press(Key.Combo(key: Key.code["return"]!, mods: []))
        } else if let browser {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        let browserURL = browser?.url ?? NSWorkspace.shared.urlForApplication(toOpen: url)
        let browserID = browserURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        Task { await ensurePlaying(browserID: browserID) }      // don't hold up the reply while the page loads
        return video.title
    }

    /// Browsers often block autoplay for pages opened from outside. Give the page a moment to start by
    /// itself; if it doesn't, bring the browser forward and press YouTube's play key, then check again.
    @MainActor
    private static func ensurePlaying(browserID: String?) async {
        let busy = Executor.busy()
        defer { ProcessInfo.processInfo.endActivity(busy) }
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(500))
            if MediaState.webMediaPlaying { return }
        }
        // Up to two presses: the first can land before the player has loaded.
        for _ in 0..<2 {
            if let browserID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first, !app.isActive {
                app.activate()
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browserID else { return }
            Keyboard.press(Key.Combo(key: Key.code["k"]!, mods: []))
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(400))
                if MediaState.webMediaPlaying { return }
            }
        }
        NSLog("Vox: YouTube video didn't start")
    }
}

/// What's playing in a browser, read from power assertions (no permissions needed). Each browser reports
/// playback its own way: WebKit names its assertion, Chrome says "Playing audio/video", Firefox and Zen hold
/// an unnamed wake lock, and Core Audio holds one on behalf of any process sending sound to the speakers.
enum MediaState {
    static var webMediaPlaying: Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let map = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let names = ["webkit media playback", "htmlmediaelement", "playing media", "playing audio", "playing video",
                     "audio-playing", "video-playing"]
        for (pid, list) in map {
            for a in list {
                let name = (a[kIOPMAssertionNameKey] as? String ?? "").lowercased()
                if names.contains(where: name.contains) { return true }
                // A browser holding a sleep assertion of its own is playing media (Firefox, Zen).
                let type = a[kIOPMAssertionTypeKey] as? String ?? ""
                if ["Prevent", "NoIdleSleep", "NoDisplaySleep"].contains(where: type.contains), isBrowser(pid.int32Value) { return true }
                // Core Audio's "sound is playing" assertion, made for the process producing the sound.
                if let owner = a["AssertionOnBehalfOfPID"] as? NSNumber, name.contains("output"), isBrowser(owner.int32Value) { return true }
            }
        }
        return false
    }

    /// A browser or one of its helper processes (audio often plays from a helper inside the app bundle).
    private static func isBrowser(_ pid: pid_t) -> Bool {
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, Executor.browserIDs.contains(id) { return true }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        return browserPaths.contains { path.hasPrefix($0) } || path.contains("com.apple.WebKit")
    }

    private static let browserPaths: [String] = Executor.browserIDs.compactMap {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path
    }.map { $0 + "/" }
}
