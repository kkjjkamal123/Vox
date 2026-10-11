import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The Settings / welcome window. Vox is a menu-bar app, so the window is created on demand.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    var speak: (String) -> Void = { _ in }

    enum Tab: String, CaseIterable, Identifiable {
        case welcome, general, voice, permissions, commands, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .general: return "General"
            case .voice: return "Voice"
            case .permissions: return "Permissions"
            case .commands: return "What Can I Say?"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .welcome: return "hand.wave.fill"
            case .general: return "gearshape.fill"
            case .voice: return "waveform"
            case .permissions: return "lock.shield.fill"
            case .commands: return "text.bubble.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    func show(_ tab: Tab = .general) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Vox"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Drop the page when closed: the hidden Permissions page would otherwise keep checking every 2 seconds.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { w.contentView = nil }
            }
        }
        window?.contentView = NSHostingView(rootView: SettingsView(initial: tab, speak: speak))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @State var selection: SettingsWindow.Tab
    let speak: (String) -> Void

    init(initial: SettingsWindow.Tab, speak: @escaping (String) -> Void) {
        _selection = State(initialValue: initial)
        self.speak = speak
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsWindow.Tab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case .welcome: WelcomePane(next: { selection = .permissions })
                    case .general: GeneralPane()
                    case .voice: VoicePane(speak: speak)
                    case .permissions: PermissionsPane()
                    case .commands: CommandsPane()
                    case .about: AboutPane()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

// MARK: Panes

private struct WelcomePane: View {
    let next: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Meet Vox").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("A voice assistant that runs on your Mac. Speech is recognized on-device, commands start while you're still talking, and it barely touches your battery.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                tip("waveform", "Say “Hey Vox”, then your command. Or hold ⌥ Space and talk.")
                tip("bolt.fill", "Chain things: “open Safari and YouTube and play a random LTT video”.")
                tip("checkmark.shield.fill", "Vox asks before sending messages or shutting down.")
                tip("menubar.rectangle", "Find Vox in the menu bar. Everything is in Settings.")
            }
            Button {
                next()
            } label: {
                Text("Set Up Permissions").frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.glassProminent)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22) }
    }
}

private struct GeneralPane: View {
    @Bindable var settings = Settings.shared
    @State private var login = Settings.shared.launchAtLogin

    var body: some View {
        Form {
            Section("Listening") {
                Toggle("Hands-free: listen for “Hey Vox”", isOn: $settings.handsFree)
                Toggle("Hear me over music (echo cancellation, uses more battery)", isOn: $settings.echoCancellation)
                Toggle("Use the Mac’s microphone when Bluetooth headphones are connected", isOn: $settings.builtInMic)
                    .help("Headphone mics switch the headphones into call mode: music sounds muffled and your first words get cut off.")
                LabeledContent("Push to talk", value: "Hold ⌥ Space · tap to toggle")
            }
            Section("Behavior") {
                Picker("Play music with", selection: $settings.musicService) {
                    ForEach(Settings.MusicService.allCases) { Text($0.title).tag($0) }
                }
                Picker("Spoken replies", selection: $settings.feedback) {
                    ForEach(Settings.Feedback.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sound effects", isOn: $settings.soundEffects)
                Toggle("Open Vox at login", isOn: $login)
                    .onChange(of: login) { _, v in Settings.shared.launchAtLogin = v; login = Settings.shared.launchAtLogin }
            }
            Section("Spotify") {
                LabeledContent("Song lookup", value: !Spotify.Credentials.saved ? "Web search (no setup)" : "Spotify API ✓")
                Text("Optional: connect a free Spotify developer app from the menu bar (Connect Spotify…) for the most accurate song matching.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoicePane: View {
    @Bindable var settings = Settings.shared
    let speak: (String) -> Void
    private let voices = Settings.americanVoices

    var body: some View {
        Form {
            Section("Vox's voice (American English)") {
                Picker("Voice", selection: $settings.voiceID) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text(v.name + (v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : "")).tag(v.identifier)
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $settings.speechRate, in: 0.4...0.62)
                }
                Button("Test Voice") { speak("Hi, I'm Vox. It's \(Date().formatted(date: .omitted, time: .shortened)), and I'm ready when you are.") }
            }
            if !settings.hasHighQualityVoice {
                Section {
                    Label("Get a natural-sounding voice", systemImage: "sparkles").font(.headline)
                    Text("Only basic American voices are installed. For a much more natural voice, download “Ava (Premium)” or “Zoe (Premium)”: System Settings → Accessibility → Read & Speak → System Voice → Manage Voices → English (United States). Then pick it here.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Read & Speak Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsPane: View {
    @State private var perms = Permissions.shared
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.largeTitle.bold())
            Text("Vox needs the first two to work. The rest unlock more commands. Nothing leaves your Mac except web lookups you ask for (weather, songs, exchange rates).")
                .foregroundStyle(.secondary)
            ForEach(Permissions.Kind.allCases) { kind in
                row(kind)
            }
        }
        .task { await perms.refresh() }
        .onReceive(timer) { _ in Task { await perms.refresh() } }
    }

    private func row(_ kind: Permissions.Kind) -> some View {
        let state = perms.states[kind] ?? .unknown
        return HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title3).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(kind.required ? Color.accentColor : Color.gray))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title + (kind.required ? "  · Required" : "")).font(.headline)
                Text(kind.why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button(state == .denied ? "Open Settings" : "Allow") { Task { await perms.request(kind) } }
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

private struct CommandsPane: View {
    @State private var query = ""
    static let catalog: [(String, String, [String])] = [
        ("Apps & web", "square.grid.2x2.fill", ["Open Safari and YouTube", "Quit Spotify", "Switch to Notes", "Go to github.com",
                                                "Search best laptops under 1 lakh", "Search cats on YouTube", "New tab · Close tab · Go back"]),
        ("Music & video", "music.note", ["Play Kesariya", "Play Arijit Singh on Spotify", "Open YouTube and play a random LTT video",
                                         "Watch the latest MKBHD video", "Play lofi beats on Apple Music", "Pause · Next song · What's playing?"]),
        ("Typing & text", "character.cursor.ibeam", ["Open Notes and type hello world… stop typing", "Summarize this", "Translate this to Hindi",
                                                    "Make this more formal", "Fix grammar", "Summarize this page", "Read my clipboard"]),
        ("Messages", "message.fill", ["Message Rahul saying I'm on my way", "WhatsApp Mom that I reached", "Email Priya about the report saying it's done"]),
        ("Time & plans", "calendar", ["Set a timer for 10 minutes", "Set an alarm for 7 AM", "Remind me to call Mom tomorrow at 9",
                                      "What's on my calendar today?", "Add meeting with Rahul tomorrow at 5", "Make a note buy milk"]),
        ("Answers", "sparkles", ["What's the weather?", "Will it rain tomorrow?", "What's 18 percent of 2400?", "Convert 100 dollars to rupees",
                                 "Who won the 2011 World Cup?", "Directions to the airport", "Coffee shops near me", "Flip a coin"]),
        ("Mac", "desktopcomputer", ["Volume 40 · Brightness 70", "Turn off Wi-Fi", "Dark mode", "Take a screenshot", "Maximize · Tile left",
                                    "Open downloads · Open Bluetooth settings", "Open file resume", "Run shortcut Good Morning", "Lock screen · Restart"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What can I say?").font(.largeTitle.bold())
            Text("Start with “Hey Vox” (or hold ⌥ Space). Join commands with “and”. Anything else is understood by the on-device model.")
                .foregroundStyle(.secondary)
            TextField("Search commands", text: $query).textFieldStyle(.roundedBorder)
            ForEach(Self.catalog, id: \.0) { group in
                let items = group.2.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(group.0, systemImage: group.1).font(.headline)
                        ForEach(items, id: \.self) { Text("“\($0)”").foregroundStyle(.secondary) }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("Vox").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("On-device speech recognition (Apple SpeechAnalyzer) and language model (Apple Intelligence). Your voice never leaves this Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}
