import AppKit
import EventKit
import UserNotifications

/// Calendar, Reminders (EventKit) and Vox's own timers and alarms.
@MainActor
final class Schedule {
    static let shared = Schedule()
    private let store = EKEventStore()

    // MARK: Dates in speech

    /// Finds a date/time in text ("tomorrow at 5pm", "on Friday", "at 7") and returns it with the text
    /// that's left once the date phrase is removed.
    static func extractDate(_ text: String, preferFuture: Bool = true) -> (Date, String)? {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), var date = m.date,
              let r = Range(m.range, in: text) else { return nil }
        if preferFuture, date < Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        var rest = text
        rest.removeSubrange(r)
        rest = rest.replacingOccurrences(of: #"\s+(at|on|for|by)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (date, rest)
    }

    static func spoken(_ date: Date) -> String {
        let cal = Calendar.current
        let t = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today at \(t)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(t)" }
        return date.formatted(.dateTime.weekday(.wide).month().day()) + " at \(t)"
    }

    // MARK: Calendar

    func agenda(dayOffset: Int) async -> String {
        guard await access(.event) else { return "I need access to your calendars. Turn it on in Vox Settings." }
        let cal = Calendar.current
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: dayOffset, to: Date())!)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { dayOffset > 0 || $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
        let day = dayOffset == 0 ? "today" : dayOffset == 1 ? "tomorrow" : "that day"
        guard !events.isEmpty else { return "Nothing on your calendar \(day)\(dayOffset == 0 ? " for the rest of the day" : "")." }
        let items = events.prefix(5).map { e in
            e.isAllDay ? "\(e.title ?? "an event"), all day" : "\(e.title ?? "an event") at \(e.startDate.formatted(date: .omitted, time: .shortened))"
        }
        return "You have \(events.count) event\(events.count == 1 ? "" : "s") \(day): " + items.joined(separator: "; ") + "."
    }

    func nextEvent() async -> String {
        guard await access(.event) else { return "I need access to your calendars. Turn it on in Vox Settings." }
        let events = store.events(matching: store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(14 * 86400), calendars: nil))
            .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        guard let e = events.first else { return "No upcoming events in the next two weeks." }
        return "Next up: \(e.title ?? "an event"), \(Self.spoken(e.startDate))."
    }

    func addEvent(_ text: String) async -> String {
        guard await access(.event) else { return "I need access to your calendars. Turn it on in Vox Settings." }
        guard let (date, rest) = Self.extractDate(text) else { return "When should I schedule it? Try: add meeting with Rahul tomorrow at 5." }
        let e = EKEvent(eventStore: store)
        e.title = rest.isEmpty ? "Event" : rest.prefix(1).uppercased() + rest.dropFirst()
        e.startDate = date
        e.endDate = date.addingTimeInterval(3600)
        e.calendar = store.defaultCalendarForNewEvents
        do { try store.save(e, span: .thisEvent) } catch { return "I couldn't save that event." }
        return "Added \(e.title!) \(Self.spoken(date))."
    }

    func addReminder(_ text: String, inSeconds: Int?) async -> String {
        guard await access(.reminder) else { return "I need access to Reminders. Turn it on in Vox Settings." }
        let r = EKReminder(eventStore: store)
        var title = text
        var due: Date?
        if let s = inSeconds { due = Date().addingTimeInterval(TimeInterval(s)) }
        else if let (d, rest) = Self.extractDate(text) { due = d; title = rest }
        r.title = title.isEmpty ? text : title.prefix(1).uppercased() + title.dropFirst()
        r.calendar = store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(r, commit: true) } catch { return "I couldn't save that reminder." }
        return "OK, I'll remind you to \(r.title!.lowercased())\(due.map { " " + Self.spoken($0) } ?? "")."
    }

    private func access(_ type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return true
        case .notDetermined:
            return (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
        default: return false
        }
    }

    // MARK: Timers & alarms

    struct Alarm: Codable, Identifiable {
        let id: UUID
        let fire: Date
        let label: String
        let isTimer: Bool
    }

    private(set) var alarms: [Alarm] = []
    private var work: [UUID: DispatchSourceTimer] = [:]
    var onFire: (Alarm) -> Void = { _ in }

    func restore() {
        guard let data = UserDefaults.standard.data(forKey: "alarms"),
              let saved = try? JSONDecoder().decode([Alarm].self, from: data) else { return }
        for a in saved where a.fire > Date() { arm(a) }
    }

    @discardableResult
    func addTimer(seconds: Int, label: String) -> String {
        arm(Alarm(id: UUID(), fire: Date().addingTimeInterval(TimeInterval(seconds)), label: label, isTimer: true))
        return "Timer set for \(label)."
    }

    func addAlarm(_ text: String) -> String {
        guard let (date, _) = Self.extractDate(text) else { return "What time? Try: set an alarm for 7 AM." }
        arm(Alarm(id: UUID(), fire: date, label: date.formatted(date: .omitted, time: .shortened), isTimer: false))
        return "Alarm set for \(Self.spoken(date)). Keep your Mac awake for it to ring."
    }

    func cancelAll() -> String {
        let n = alarms.count
        work.values.forEach { $0.cancel() }
        work = [:]; alarms = []
        persist()
        return n == 0 ? "You don't have any timers or alarms." : "Cancelled \(n) timer\(n == 1 ? "" : "s") and alarms."
    }

    func cancel(_ id: UUID) {
        work[id]?.cancel(); work[id] = nil
        alarms.removeAll { $0.id == id }
        persist()
    }

    func timeLeft() -> String {
        guard let t = alarms.filter({ $0.isTimer }).min(by: { $0.fire < $1.fire }) else {
            if let a = alarms.first { return "Your next alarm is \(Self.spoken(a.fire))." }
            return "You don't have any timers running."
        }
        let s = Int(t.fire.timeIntervalSinceNow)
        let m = s / 60, r = s % 60
        return m > 0 ? "\(m) minute\(m == 1 ? "" : "s") and \(r) seconds left on your \(t.label) timer."
            : "\(r) seconds left on your \(t.label) timer."
    }

    private func arm(_ a: Alarm) {
        alarms.append(a)
        // A strict wall-clock timer: App Nap may otherwise hold an ordinary one back by tens of seconds.
        let w = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        w.schedule(wallDeadline: .now() + max(0, a.fire.timeIntervalSinceNow), leeway: .milliseconds(100))
        w.setEventHandler { [weak self] in
            guard let self else { return }
            w.cancel()
            alarms.removeAll { $0.id == a.id }
            work[a.id] = nil
            persist()
            onFire(a)
            let n = UNMutableNotificationContent()
            n.title = a.isTimer ? "Timer done" : "Alarm"
            n.body = a.isTimer ? "Your \(a.label) timer is done." : "It's \(a.label)."
            n.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id.uuidString, content: n, trigger: nil))
        }
        work[a.id] = w
        w.resume()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alarms), forKey: "alarms")
    }
}
