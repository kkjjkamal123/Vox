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
        // Only letters and digits reach the Spotlight query: quotes, `*` or `\` would change its meaning.
        let words = query.split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let predicate = words.map { "kMDItemDisplayName == '*\($0)*'cd" }.joined(separator: " && ")
        let output = await Self.output("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), predicate], timeout: 10)
        let paths = output.split(separator: "\n").prefix(2000).map(String.init)
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
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Runs a tool off the main thread and returns what it printed. The output is read *while* it runs:
    /// waiting for the exit first deadlocks as soon as the tool prints more than a pipe holds (64 KB, e.g.
    /// Spotlight matching thousands of files), which used to stall every later voice command for good.
    /// A tool still running after `timeout` seconds is terminated.
    nonisolated static func output(_ path: String, _ args: [String], timeout: Double) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
