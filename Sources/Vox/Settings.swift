import AppKit
import AVFoundation
import ApplicationServices
import Contacts
import CoreLocation
import EventKit
import ServiceManagement
import UserNotifications

/// User preferences, persisted in UserDefaults and observable from SwiftUI.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum MusicService: String, CaseIterable, Identifiable {
        case auto, spotify, youtube, appleMusic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .spotify: return "Spotify"
            case .youtube: return "YouTube"
            case .appleMusic: return "Apple Music"
            }
        }
    }

    enum Feedback: String, CaseIterable, Identifiable {
        case quiet, answers, everything
        var id: String { rawValue }
        var title: String {
            switch self {
            case .quiet: return "Silent"
            case .answers: return "Answers and questions"
            case .everything: return "Everything"
            }
        }
    }

    var handsFree: Bool { didSet { d.set(handsFree, forKey: "handsFree"); onChange() } }
    var echoCancellation: Bool { didSet { d.set(echoCancellation, forKey: "echoCancellation"); onChange() } }
    /// Listen with the Mac's mic while Bluetooth headphones are connected (keeps their music quality).
    var builtInMic: Bool { didSet { d.set(builtInMic, forKey: "builtInMic"); onChange() } }
    var soundEffects: Bool { didSet { d.set(soundEffects, forKey: "soundEffects") } }
    var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    var musicService: MusicService { didSet { d.set(musicService.rawValue, forKey: "musicService") } }
    var feedback: Feedback { didSet { d.set(feedback.rawValue, forKey: "feedback") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    /// Called when a setting that affects the listener changes.
    @ObservationIgnored var onChange: () -> Void = {}

    private init() {
        handsFree = d.object(forKey: "handsFree") as? Bool ?? true
        echoCancellation = d.bool(forKey: "echoCancellation")
        builtInMic = d.object(forKey: "builtInMic") as? Bool ?? true
        soundEffects = d.object(forKey: "soundEffects") as? Bool ?? true
        voiceID = d.string(forKey: "voiceID") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        musicService = MusicService(rawValue: d.string(forKey: "musicService") ?? "") ?? .auto
        feedback = Feedback(rawValue: d.string(forKey: "feedback") ?? "") ?? .answers
        onboarded = d.bool(forKey: "onboarded")
    }

    /// Where "play X" goes when no service is named.
    var effectiveMusicService: MusicService {
        if musicService != .auto { return musicService }
        return Spotify.isInstalled ? .spotify : .youtube
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("Vox: login item: \(error)") }
        }
    }

    // MARK: Voice

    /// US English voices, best first. Novelty voices are left out.
    static var americanVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name == "Samantha" ? 1 : 0) > ($1.quality.rawValue, $1.name == "Samantha" ? 1 : 0) }
    }

    var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: voiceID) ?? Self.americanVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    var hasHighQualityVoice: Bool { Self.americanVoices.contains { $0.quality != .default } }
}

/// Status and requests for every permission Vox can use.
@MainActor @Observable
final class Permissions {
    static let shared = Permissions()

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, automation, calendars, reminders, contacts, location, notifications
        var id: String { rawValue }
        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .automation: return "Automation"
            case .calendars: return "Calendars"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            case .location: return "Location"
            case .notifications: return "Notifications"
            }
        }
        var why: String {
            switch self {
            case .microphone: return "Hear your voice. Required."
            case .accessibility: return "Type, press keys and control windows. Required."
            case .automation: return "Control apps like Spotify, Notes and System Events."
            case .calendars: return "Read your schedule and add events."
            case .reminders: return "Create reminders."
            case .contacts: return "Find people to message or email."
            case .location: return "Local weather."
            case .notifications: return "Timer and alarm alerts."
            }
        }
        var symbol: String {
            switch self {
            case .microphone: return "mic.fill"
            case .accessibility: return "accessibility"
            case .automation: return "gearshape.2.fill"
            case .calendars: return "calendar"
            case .reminders: return "checklist"
            case .contacts: return "person.crop.circle"
            case .location: return "location.fill"
            case .notifications: return "bell.badge.fill"
            }
        }
        var required: Bool { self == .microphone || self == .accessibility }
    }

    enum State { case granted, denied, unknown }

    private(set) var states: [Kind: State] = [:]
    private let locationManager = CLLocationManager()

    func refresh() async {
        var s: [Kind: State] = [:]
        s[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .unknown
            default: .denied
        }
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        s[.automation] = await automationSummary()
        s[.calendars] = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? .granted
            : EKEventStore.authorizationStatus(for: .event) == .notDetermined ? .unknown : .denied
        s[.reminders] = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? .granted
            : EKEventStore.authorizationStatus(for: .reminder) == .notDetermined ? .unknown : .denied
        s[.contacts] = switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized, .limited: .granted
            case .notDetermined: .unknown
            default: .denied
        }
        s[.location] = switch locationManager.authorizationStatus {
            case .authorized, .authorizedAlways: .granted
            case .notDetermined: .unknown
            default: .denied
        }
        let n = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        s[.notifications] = n == .authorized || n == .provisional ? .granted : n == .notDetermined ? .unknown : .denied
        states = s
    }

    func request(_ kind: Kind) async {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            else { openPane("Privacy_Microphone") }
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            openPane("Privacy_Accessibility")
        case .automation:
            // macOS can only ask about an app that's running, so each one is opened out of sight first.
            for id in Self.automationTargets where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                if Player.running(id), await Script.automation(id, wait: 1) != .unknown { continue }
                let launched = await openHidden(id)
                _ = await Script.automation(id, ask: true, wait: 60)
                if launched { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() } }
            }
            if await automationSummary() == .denied { openPane("Privacy_Automation") }
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = try? await EKEventStore().requestFullAccessToEvents() }
            else { openPane("Privacy_Calendars") }
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { _ = try? await EKEventStore().requestFullAccessToReminders() }
            else { openPane("Privacy_Reminders") }
        case .contacts:
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined { _ = try? await CNContactStore().requestAccess(for: .contacts) }
            else { openPane("Privacy_Contacts") }
        case .location:
            if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
            else { openPane("Privacy_LocationServices") }
        case .notifications:
            let c = UNUserNotificationCenter.current()
            if await c.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await c.requestAuthorization(options: [.alert, .sound])
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    /// Apps Vox scripts. macOS lists an app under Automation only after Vox has asked about it.
    static let automationTargets = ["com.apple.systemevents", "com.spotify.client", "com.apple.Music", "com.apple.Notes",
                                    "com.apple.MobileSMS", "com.apple.finder"]

    /// Denied if any running target app is denied, allowed if all of them are. Apps that aren't running can't
    /// be checked, so they're left out.
    private func automationSummary() async -> State {
        var states: [State] = []
        for id in Self.automationTargets where Player.running(id) { states.append(await Script.automation(id, wait: 1) ?? .unknown) }
        if states.contains(.denied) { return .denied }
        return !states.isEmpty && states.allSatisfy { $0 == .granted } ? .granted : .unknown
    }

    /// Start an app hidden and in the background; true if this launched it.
    private func openHidden(_ id: String) async -> Bool {
        guard !Player.running(id), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg) else { return false }
        for _ in 0..<40 where !app.isFinishedLaunching { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))   // until it's reachable by Apple Events
        return true
    }

    private func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    /// Apple Events permission for one target app, optionally showing the system prompt.
    nonisolated static func automationState(_ bundleID: String, ask: Bool = false) -> State {
        var target = AEAddressDesc()
        let data = Array(bundleID.utf8)
        AECreateDesc(typeApplicationBundleID, data, data.count, &target)
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
        case OSStatus(procNotFound): return .unknown
        default: return .denied
        }
    }
}
