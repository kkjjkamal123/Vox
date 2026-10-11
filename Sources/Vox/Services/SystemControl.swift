import AppKit

/// Power, brightness, storage, files and app management.
@MainActor
enum SystemControl {
    enum Power: String { case sleep, restart, shutdown, logout }

    static func perform(_ p: Power) async {
        switch p {
        case .sleep: run("/usr/bin/pmset", ["sleepnow"])
        case .restart: await Script.run("tell application \"System Events\" to restart")
        case .shutdown: await Script.run("tell application \"System Events\" to shut down")
        case .logout: await Script.run("tell application \"System Events\" to log out")
        }
    }

    /// There's no public API to set brightness, so step the brightness keys: all the way down, then up.
    static func setBrightness(_ percent: Int) async {
        for _ in 0..<16 { Keyboard.media(3); try? await Task.sleep(for: .milliseconds(15)) }
        for _ in 0..<Int((Double(percent) / 6.25).rounded()) { Keyboard.media(2); try? await Task.sleep(for: .milliseconds(15)) }
    }

    static func storage() -> String {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return "I couldn't read your disk." }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: free)) free of \(f.string(fromByteCount: Int64(total)))."
    }

    /// Spotlight search by name, most recently used first. Returns the opened file's name.
    static func openFile(_ query: String) async -> String? {
        let words = query.split(separator: " ").map { $0.replacingOccurrences(of: "'", with: "") }
        let predicate = words.map { "kMDItemDisplayName == '*\($0)*'cd" }.joined(separator: " && ")
        let output = await Task.detached { () -> String in
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", NSHomeDirectory(), predicate]
            p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
        let paths = output.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.hasSuffix(".app") }
        let best = paths.map { p -> (String, Date) in
            let d = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            return (p, d)
        }.max { $0.1 < $1.1 }?.0
        guard let best else { return nil }
        NSWorkspace.shared.open(URL(fileURLWithPath: best))
        return (best as NSString).lastPathComponent
    }

    static func quitAllApps() -> Int {
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder" && $0.bundleIdentifier != me
        }
        apps.forEach { $0.terminate() }
        return apps.count
    }

    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}
