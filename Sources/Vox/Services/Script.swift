import AppKit

/// AppleScript off the main thread, with a time limit. A busy or launching app (Spotify starting up,
/// Messages syncing) can take seconds to answer an Apple Event, and with NSAppleScript's default two-minute
/// timeout on the main thread that froze Vox's popup, hotkey and recognizer for as long as it took.
///
/// AppleScript's own `with timeout` doesn't cover a pending "allow Vox to control …?" question, which waits
/// for the user indefinitely (forever, if the screen is locked). So each script also has a hard deadline, and
/// scripts run concurrently, so one stuck script can't hold up the rest.
enum Script {
    private static let queue = DispatchQueue(label: "vox.applescript", qos: .userInitiated, attributes: .concurrent)

    /// The script's result as text ("" for no result), or nil if it failed or timed out.
    @discardableResult
    static func run(_ source: String, timeout seconds: Int = 6) async -> String? {
        await withCheckedContinuation { cont in
            let once = Once()
            queue.async {
                var err: NSDictionary?
                let wrapped = "with timeout of \(seconds) seconds\n\(source)\nend timeout"
                let r = NSAppleScript(source: wrapped)?.executeAndReturnError(&err)
                if let err { NSLog("Vox AppleScript error: \(err)") }
                if once.claim() { cont.resume(returning: err == nil ? (r?.stringValue ?? "") : nil) }
            }
            queue.asyncAfter(deadline: .now() + .seconds(seconds + 1)) {
                if once.claim() { NSLog("Vox: AppleScript didn't answer in time"); cont.resume(returning: nil) }
            }
        }
    }

    /// Whether Vox may send Apple Events to an app. If macOS still needs to ask, the question is shown and
    /// this waits up to `wait` seconds for the answer. Apps that aren't running count as allowed (scripting
    /// them launches them, and macOS asks then). They aren't even checked: after an app crashes, macOS can
    /// keep its dead copy registered, and every permission check for it then hangs until the app relaunches.
    static func allowed(_ bundleID: String, wait: Double = 2) async -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return true }
        switch await automation(bundleID, wait: 2) {
        case .granted: return true
        case .denied: return false
        case .unknown?: return await automation(bundleID, ask: true, wait: wait) == .granted
        case nil: return false        // macOS didn't answer: a question is already waiting for the user
        }
    }

    /// The Apple Events permission for an app, or nil if macOS didn't answer in time. Even asking without
    /// prompting can block while another permission question is on screen (or can't be shown, on the lock
    /// screen), so it runs on this queue with a deadline, never on the main thread or Swift's shared threads.
    static func automation(_ bundleID: String, ask: Bool = false, wait: Double) async -> Permissions.State? {
        await withCheckedContinuation { cont in
            let once = Once()
            queue.async {
                let s = Permissions.automationState(bundleID, ask: ask)
                if once.claim() { cont.resume(returning: s) }
            }
            queue.asyncAfter(deadline: .now() + wait) { if once.claim() { cont.resume(returning: nil) } }
        }
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
