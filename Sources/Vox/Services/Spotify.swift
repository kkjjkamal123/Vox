import AppKit
import Security

/// "Play X" in the Spotify desktop app.
///
/// Spotify's AppleScript can play an exact track URI but not a search, and its window doesn't expose
/// results to Accessibility, so the song name is resolved to a track ID first:
///  1. Spotify Web API search, if the user connected a (free) developer app — reliable.
///  2. Otherwise a web-search lookup for an open.spotify.com/track link — no setup, best effort.
///  3. Otherwise nil, and the executor plays it on YouTube instead.
@MainActor
enum Spotify {
    nonisolated static let bundleID = "com.spotify.client"
    nonisolated static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    private static var token: (value: String, expires: Date)?
    /// Artist of the song Vox last started, so "next" can continue with more of their songs.
    private static var artist: String?

    /// "Next track" on a single has nothing to skip to; continue with the artist's songs instead.
    static func next() async {
        let before = await run("tell application \"Spotify\" to return id of current track")
        await run("tell application \"Spotify\" to next track")
        try? await Task.sleep(for: .milliseconds(700))
        guard let artist, await run("tell application \"Spotify\" to return id of current track") == before else { return }
        await run("tell application \"Spotify\" to play track \"\(artist)\"")
    }

    /// Returns what was played, or nil if nothing playable was found.
    @discardableResult
    static func play(_ query: String, log: ((String) -> Void)? = nil) async -> String? {
        await play(candidates: search(query, log: log), query: query, log: log)
    }

    /// Tracks matching a song name, best first, as "uri|album uri|artist uri|title".
    static func search(_ query: String, log: ((String) -> Void)? = nil) async -> [String] {
        if let creds = await Credentials.load() {
            let found = await apiSearch(query, creds: creds)
            log?("web api: \(found)")
            if !found.isEmpty { return found }
        }
        let found = await webLookup(query)
        log?("web lookup: \(found)")
        return found
    }

    /// Whether any match is titled like what was asked for (so the title needs no correcting).
    static func confident(_ candidates: [String], for query: String) -> Bool {
        candidates.prefix(3).contains { c in
            let parts = c.components(separatedBy: "|")
            return parts.count > 3 && sameSong(parts[3], query)
        }
    }

    static func play(candidates found: [String], query: String, log: ((String) -> Void)? = nil) async -> String? {
        guard !found.isEmpty else { return nil }
        // Results titled like the request go first (search engines don't always rank the original on top).
        let titled = found.filter { c in let p = c.components(separatedBy: "|"); return p.count > 3 && sameSong(p[3], query) }
        let candidates = titled + found.filter { !titled.contains($0) }
        let cold = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if cold, !(await Player.launch(bundleID, app: "Spotify")) { return nil }
        // A track can be unavailable in the user's country; Spotify then silently skips to the next one.
        // Confirm the requested track is really playing, else try the next match.
        for (i, uri) in candidates.prefix(4).enumerated() {
            if let playing = await playAndVerify(uri, query: query, patience: cold && i == 0 ? 7 : 4) {
                log?("playing \(uri)")
                return playing
            }
            log?("skipped by Spotify: \(uri)")
        }
        return nil
    }

    private static func playAndVerify(_ candidate: String, query: String, patience: Double) async -> String? {
        let parts = candidate.components(separatedBy: "|"), uri = parts[0]
        let context = parts.count > 1 && !parts[1].isEmpty ? " in context \"\(parts[1])\"" : ""
        artist = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let before = await run("tell application \"Spotify\" to return id of current track") ?? ""
        guard await run("tell application \"Spotify\" to play track \"\(uri)\"\(context)") != nil else { return nil }
        let start = Date()
        while Date().timeIntervalSince(start) < patience {
            try? await Task.sleep(for: .milliseconds(200))
            guard let id = await run("tell application \"Spotify\" to return id of current track"), !id.isEmpty else { continue }
            if id == before && id != uri { continue }                 // hasn't switched yet
            guard await run("tell application \"Spotify\" to return player state as text") == "playing" else { continue }
            let name = await run("tell application \"Spotify\" to return (name of current track) & \" — \" & (artist of current track)")
            if id == uri { return name }
            // Spotify may play a region-specific copy of the same song under another ID: fine. Anything else
            // means it skipped the requested track.
            if let name, sameSong(name, query) { return name }
            if Date().timeIntervalSince(start) > 1.5 { return nil }
        }
        return nil
    }

    /// Whether "Kesariya — Pritam, Arijit Singh" is the song asked for as "kesariya by arijit".
    static func sameSong(_ playing: String, _ query: String) -> Bool {
        let title = playing.components(separatedBy: " — ")[0].lowercased().filter(\.isLetter)
        let asked = query.components(separatedBy: " by ")[0].lowercased().filter(\.isLetter)
        guard title.count >= 3, asked.count >= 3 else { return title == asked && !title.isEmpty }
        let contains = asked.count >= 4 && title.contains(asked) || title.count >= 4 && asked.contains(title)
        return contains || Brain.similarity(title, asked) >= 0.6
    }

    @discardableResult
    private static func run(_ script: String) async -> String? { await Script.run(script, timeout: 4) }

    // MARK: Web API (client credentials; search only, no user login)

    private static func apiSearch(_ query: String, creds: Credentials) async -> [String] {
        guard let token = await accessToken(creds) else { return [] }
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        // "kesariya by arijit" searches the title and artist fields separately.
        let parts = query.components(separatedBy: " by ")
        let q = parts.count == 2 ? "track:\(parts[0]) artist:\(parts[1])" : query
        c.queryItems = [.init(name: "q", value: q), .init(name: "type", value: "track"), .init(name: "limit", value: "5"),
                        .init(name: "market", value: Locale.current.region?.identifier ?? "US")]
        var req = URLRequest(url: c.url!, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        // "track|album|artist" so the track plays inside its album and "next track" has somewhere to go.
        return items.compactMap { item in
            guard let uri = item["uri"] as? String else { return nil }
            let album = (item["album"] as? [String: Any])?["uri"] as? String ?? ""
            let artist = ((item["artists"] as? [[String: Any]])?.first?["uri"] as? String) ?? ""
            let name = (item["name"] as? String ?? "").replacingOccurrences(of: "|", with: " ")
            return [uri, album, artist, name].joined(separator: "|")
        }
    }

    private static func accessToken(_ creds: Credentials) async -> String? {
        if let t = token, t.expires > Date() { return t.value }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(creds.id):\(creds.secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["access_token"] as? String else { return nil }
        let ttl = (json["expires_in"] as? Double) ?? 3600
        token = (value, Date().addingTimeInterval(ttl - 60))
        return value
    }

    // MARK: No-setup fallback

    private static func webLookup(_ query: String) async -> [String] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: "spotify track \(query)")]
        var req = URLRequest(url: c.url!, timeoutInterval: 5)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8) else { return [] }
        // Result titles tell the original apart from remixes, lofi edits, covers…
        let variants = ["remix", "mix", "lofi", "lo-fi", "slowed", "reverb", "sped up", "cover", "karaoke", "instrumental", "8d", "mashup", "version"]
        let asked = query.lowercased()
        var originals: [String] = [], others: [String] = []
        for m in html.matches(of: #/class="result__a" href="([^"]+)"[^>]*>(.*?)</a>/#.dotMatchesNewlines()) {
            let href = String(m.1).removingPercentEncoding ?? String(m.1)
            guard let id = href.firstMatch(of: #/open\.spotify\.com/track/([A-Za-z0-9]{22})/#)?.1 else { continue }
            let title = String(m.2).replacing(#/<[^>]+>/#, with: "").lowercased()
            // "Kesariya - song and lyrics by Pritam, Arijit Singh | Spotify" -> "kesariya"
            let name = title.components(separatedBy: " | ")[0].components(separatedBy: " - ")[0].replacingOccurrences(of: "|", with: " ")
            let uri = "spotify:track:" + id
            guard !originals.contains(where: { $0.hasPrefix(uri + "|") }), !others.contains(where: { $0.hasPrefix(uri + "|") }) else { continue }
            let entry = [uri, "", "", name].joined(separator: "|")
            if variants.contains(where: { title.contains($0) && !asked.contains($0) }) { others.append(entry) } else { originals.append(entry) }
        }
        let found = originals + others
        if !found.isEmpty { return found }
        return html.firstMatch(of: #/open\.spotify\.com(?:%2F|\/)track(?:%2F|\/)([A-Za-z0-9]{22})/#).map { ["spotify:track:" + $0.1] } ?? []
    }

    // MARK: Credentials (Keychain)

    struct Credentials {
        let id: String, secret: String
        nonisolated private static let service = "local.vox.spotify"

        private static var cached: Credentials?
        private static var loading: Task<Credentials?, Never>?
        /// The user said no to keychain access: don't ask again on every song (until they reconnect).
        private static var refused = false

        /// Whether a pair is saved. Reads only the item's attributes, which never makes macOS ask the user
        /// for keychain access (so the menu and Settings can show it without freezing).
        static var saved: Bool {
            if cached != nil { return true }
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true]
            return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
        }

        /// The saved pair, read once off the main thread. Reading the secret can make macOS ask "allow Vox to
        /// use the keychain?" (after an update, for example), and that question used to freeze all of Vox until
        /// answered. Now Vox waits at most 2 s, then carries on without it (songs are found by web search).
        static func load() async -> Credentials? {
            if let cached { return cached }
            guard !refused, saved else { return nil }
            let task = loading ?? Task.detached(priority: .userInitiated) { readKeychain() }
            loading = task
            return await withCheckedContinuation { cont in
                var done = false
                Task { @MainActor in
                    let v = await task.value
                    cached = v; loading = nil
                    if v == nil { refused = true }
                    if !done { done = true; cont.resume(returning: v) }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if !done { done = true; cont.resume(returning: nil) }
                }
            }
        }

        private nonisolated static func readKeychain() -> Credentials? {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let item = out as? [String: Any],
                  let id = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data, let secret = String(data: data, encoding: .utf8) else { return nil }
            return Credentials(id: id, secret: secret)
        }

        static func save(id: String, secret: String) {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecAttrAccount as String] = id
            add[kSecValueData as String] = Data(secret.utf8)
            SecItemAdd(add as CFDictionary, nil)
            cached = Credentials(id: id, secret: secret)
            refused = false
        }

        /// Checks the pair against Spotify before saving.
        @MainActor static func verify(id: String, secret: String) async -> Bool {
            Spotify.token = nil
            return await Spotify.accessToken(Credentials(id: id, secret: secret)) != nil
        }
    }
}
