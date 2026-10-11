import AVFoundation
import AppKit
import ApplicationServices

// `Vox --simulate "open safari and youtube"` feeds the text word by word, the way live recognition does,
// and prints each action at the moment it would fire. Nothing is executed. With `--wake`, the text must
// contain "hey vox" and only what follows it is treated as a command.
let args = CommandLine.arguments

// `Vox --render-hud <dir>`: write the HUD design, light and dark, as PNGs.
if let i = args.firstIndex(of: "--render-hud"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        HUD.renderSample(to: args[i + 1] + "/hud-light.png", dark: false)
        HUD.renderSample(to: args[i + 1] + "/hud-dark.png", dark: true)
    }
    exit(0)
}

// `Vox --hud-test <seconds>`: show the live popup listening to a fake voice, to measure what drawing it costs.
if let i = args.firstIndex(of: "--hud-test"), i + 1 < args.count, let secs = Double(args[i + 1]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let hud = HUD()
        hud.show()
        hud.setListening(true)
        hud.text(final: "Open YouTube and play a random", volatile: "LTT video")
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { hud.level(Float(0.3 + 0.3 * sin(Date().timeIntervalSince(t0) * 6))) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }
    app.run()
}

if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let s = CommandStream()
        var step = ""
        s.emit = { print("   \(step)  →  \($0)") }
        s.onUnparsed = { print("   \(step)  →  [to on-device model] \"\($0)\"") }
        var words = args[i + 1].split(separator: " ").map(String.init)
        if args.contains("--wake") {
            guard let m = Wake.find(raw: words.filter { $0 != "--" }) else { print("   (no wake word — ignored)"); return }
            print("   woke at \"\(words[..<m.next].joined(separator: " "))\"\(m.strong ? "" : " (weak: rules only)")")
            words = Array(words[m.next...])
        }
        guard !words.isEmpty else { return }
        // "--" marks a pause: the recognizer commits the words so far and the settle timer fires, as happens
        // when someone stops to think mid-sentence ("quit -- spotify").
        var final: [String] = [], volatile: [String] = []
        for w in words {
            if w == "--" {
                final += volatile; volatile = []
                step = "pause after \"\(final.joined(separator: " "))\""
                s.update(final: final.joined(separator: " "), volatile: "")
                s.settle()
                continue
            }
            volatile.append(w)
            step = "heard \"\((final + volatile).joined(separator: " "))\""
            s.update(final: final.joined(separator: " "), volatile: volatile.joined(separator: " "))
            s.update(final: final.joined(separator: " "), volatile: volatile.joined(separator: " "))   // a second, unchanged partial
        }
        step = "final"
        s.finish(final: (final + volatile).joined(separator: " "))
    }
    exit(0)
}

// `Vox --brain "<utterance>"`: show what the on-device model does with a phrase the rules don't know.
if let i = args.firstIndex(of: "--brain"), i + 1 < args.count {
    _ = MainActor.assumeIsolated {
        Task { @MainActor in
            let brain = Brain()
            var t = Date()
            let cmds = await brain.rewrite(args[i + 1])
            print("rewrite (\(Int(Date().timeIntervalSince(t) * 1000)) ms): \(cmds)")
            if let q = cmds.first(where: { $0.hasPrefix("ask ") }) {
                t = Date()
                let a = await brain.answer(String(q.dropFirst(4)))
                print("answer (\(Int(Date().timeIntervalSince(t) * 1000)) ms): \(a)")
            }
            exit(0)
        }
    }
    RunLoop.main.run()
}

// `Vox --listen-test <seconds> <logfile> [--no-vp]`: listen once and log every transcript update with its
// time, for checking recognition quality and latency. Launch via `open -n` so it has Vox's mic permission.
if let i = args.firstIndex(of: "--listen-test"), i + 2 < args.count, let secs = Double(args[i + 1]) {
    let path = args[i + 2]
    MainActor.assumeIsolated {
        let l = Listener()
        l.voiceProcessing = !args.contains("--no-vp")
        l.preferBuiltInMic = !args.contains("--default-mic")
        if let e = args.firstIndex(of: "--engine"), e + 1 < args.count, let kind = Listener.Engine(rawValue: args[e + 1]) { l.engine = kind }
        l.silenceTimeout = secs; l.initialTimeout = secs
        l.chooseFinal = { best, alts in
            let top = Parser.score(best)
            return alts.map { ($0, Parser.score($0)) }.filter { $0.1 > top + 1 }.max { $0.1 < $1.1 }?.0 ?? best
        }
        let t0 = Date()
        var lines = ["vp=\(l.voiceProcessing) engine=\(l.engine)"]
        func flush() { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        l.onText = { f, v in lines.append(String(format: "%5.2fs  final=[%@]  volatile=[%@]", Date().timeIntervalSince(t0), f, v)) }
        var peak: Float = 0
        l.reportsLevel = true
        l.onLevel = { peak = max(peak, $0) }
        l.onEnded = { f in lines.append("peak level: \(peak)"); lines.append("ended: \(f)"); flush(); exit(0) }
        Task { @MainActor in
            do {
                try await l.prepare(contextNames: Parser.vocabulary + AppIndex.shared.contextualNames)
                try await l.start(continuous: args.contains("--continuous"))
                lines.append(String(format: "%5.2fs  listening", Date().timeIntervalSince(t0)))
                lines.append(l.diagnostics)
                if let d = AudioDevices.defaultInput() { lines.append("io buffer after start: \(AudioDevices.bufferFrames(d)) frames") }
                flush()
                try? await Task.sleep(for: .seconds(secs))
                lines.append("peak level: \(peak), mic auth: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), \(l.gateStats)")
                flush()
                await l.stop()
            } catch { lines.append("error: \(error)"); flush(); exit(1) }
        }
    }
    RunLoop.main.run()
}

// `Vox --permissions <logfile>`: Apple Events permission for each app Vox scripts (launch via `open -n`).
if let i = args.firstIndex(of: "--permissions"), i + 1 < args.count {
    let path = args[i + 1]
    Task {
        var lines: [String] = []
        for id in ["com.spotify.client", "com.apple.Music", "com.apple.systemevents", "com.apple.Notes", "com.apple.MobileSMS", "com.apple.finder"] {
            let s = await Script.automation(id, wait: 3)
            lines.append("\(id): \(s.map { "\($0)" } ?? "no answer (a permission question is pending)")")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }
    RunLoop.main.run()
}

// `Vox --lifecycle-test <logfile>`: start and stop the listener rapidly (overlapping, mid-start) and check it
// never hangs, never ends up half-open, and closes the mic at the end.
if let i = args.firstIndex(of: "--lifecycle-test"), i + 1 < args.count {
    let path = args[i + 1]
    MainActor.assumeIsolated {
        let l = Listener()
        var lines: [String] = []
        var ended = 0
        l.onEnded = { _ in ended += 1 }
        func flush() { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { lines.append("HUNG"); flush(); exit(1) }
        Task { @MainActor in
            let t0 = Date()
            try? await l.prepare(contextNames: [])
            var failures = 0
            for n in 0..<30 {
                let continuous = n % 2 == 0
                switch n % 3 {
                case 0:   // normal start, then stop
                    do { try await l.start(continuous: continuous) } catch { failures += 1 }
                    try? await Task.sleep(for: .milliseconds(150))
                    await l.stop()
                case 1:   // stop while start is still in progress
                    let s = Task { @MainActor in try? await l.start(continuous: continuous) }
                    try? await Task.sleep(for: .milliseconds(20))
                    await l.stop()
                    await s.value
                    await l.stop()
                default:  // start again before the previous stop finished
                    try? await l.start(continuous: continuous)
                    let stop = Task { @MainActor in await l.stop() }
                    do { try await l.start(continuous: !continuous) } catch { failures += 1 }
                    await stop.value
                    await l.stop()
                }
                if l.running { lines.append("cycle \(n): still running after stop") }
            }
            lines.append(String(format: "30 cycles in %.1fs, start errors: %d, onEnded calls: %d, running at end: %@",
                                Date().timeIntervalSince(t0), failures, ended, l.running ? "YES" : "no"))
            flush(); exit(0)
        }
    }
    RunLoop.main.run()
}

// `Vox --song "<misheard title>"`: what the song-title correction makes of it.
if let i = args.firstIndex(of: "--song"), i + 1 < args.count {
    _ = MainActor.assumeIsolated {
        Task { @MainActor in
            let t = Date()
            let fixed = await Brain().correctSong(args[i + 1])
            print("\(args[i + 1]) -> \(fixed)  (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
            exit(0)
        }
    }
    RunLoop.main.run()
}

// `Vox --exec "<command>" <logfile>`: run one spoken command through the real parser and executor and log
// every action and outcome. It really executes. Launch via `open -n` so it has Vox's permissions.
if let i = args.firstIndex(of: "--exec"), i + 2 < args.count {
    let path = args[i + 2]
    _ = Executor.busy()
    MainActor.assumeIsolated {
        let brain = Brain()
        let exec = Executor(brain: brain)
        let stream = CommandStream()
        var lines: [String] = []
        var pending = 0
        func flush() { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        let t0 = Date()
        exec.onDone = { a, o in
            lines.append(String(format: "%5.2fs  %@  →  %@", Date().timeIntervalSince(t0), a.description, "\(o)"))
            pending -= 1
            flush()
            // Linger so background follow-ups (e.g. making sure a video starts) can finish.
            if pending <= 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) } }
        }
        stream.emit = { pending += 1; exec.enqueue($0) }
        stream.onUnparsed = { text in
            lines.append("unparsed: \(text)")
            pending += 1
            Task { @MainActor in
                let cmds = await brain.rewrite(text)
                lines.append("model: \(cmds)")
                pending -= 1
                let s2 = CommandStream()
                s2.emit = { pending += 1; exec.enqueue($0) }
                for c in cmds { s2.runOnce(c) }
                flush()
                if pending <= 0 { exit(0) }
            }
        }
        stream.runOnce(args[i + 1])
        flush()
        if pending == 0 { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { lines.append("timeout"); flush(); exit(1) }
    }
    // The real app's event loop: AppleScript sets up the process as an app, after which a bare run loop
    // stops serving the main queue and the command never finishes.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}

// `Vox --test-spotify "<query>" <logfile>`: run the Spotify player once and log what it saw. Launch it with
// `open -n build/Vox.app --args ...` so it runs with Vox's own Accessibility permission.
if let i = args.firstIndex(of: "--test-spotify"), i + 2 < args.count {
    let logURL = URL(fileURLWithPath: args[i + 2])
    MainActor.assumeIsolated {
        var lines = ["trusted: \(AXIsProcessTrusted())"]
        Task { @MainActor in
            let played = await Spotify.play(args[i + 1]) { lines.append($0) }
            lines.append("played: \(played ?? "nothing found")")
            try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
