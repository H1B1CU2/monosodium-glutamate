import AppKit
import EventKit

/// The next thing on the calendar or the reminder list, shared by the menu bar
/// countdown (`CalendarStatusItem`) and the Edge Keys esc-spot widget.
final class CalendarFeed {
    static let shared = CalendarFeed()

    struct Entry {
        let title: String
        /// Start of an event, or when a reminder is due.
        let date: Date
        /// End of an event under way.
        let end: Date?
        let isReminder: Bool
        let calendarColor: NSColor?
        /// A reminder due on a day, with no time of day.
        var allDay = false
    }

    private let store = EKEventStore()
    private(set) var eventsAllowed = false
    private(set) var remindersAllowed = false
    private var reminders: [EKReminder] = []
    private var readingReminders = false
    private var remindersReadAt: Date = .distantPast
    private var started = false
    private var observers: [UUID: () -> Void] = [:]

    /// How far ahead events are looked for; further only when nothing is
    /// found in it (then at most once an hour).
    private static let nearHorizon: TimeInterval = 30 * 24 * 3600
    private static let farHorizon: TimeInterval = 366 * 24 * 3600
    private var farEvents: [Entry] = []
    private var farEventsReadAt: Date = .distantPast

    private init() {}

    /// Told on the main queue whenever what's coming up may have changed.
    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() { observers.values.forEach { $0() } }

    /// Asks for access (once) and starts following the store.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .EKEventStoreChanged, object: store)
        eventsAllowed = Self.authorized(for: .event)
        remindersAllowed = Self.authorized(for: .reminder)
        if !eventsAllowed { request(.event) }
        if !remindersAllowed { request(.reminder) }
        refresh()
    }

    private func request(_ type: EKEntityType) {
        let done: (Bool, Error?) -> Void = { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if type == .event { self.eventsAllowed = granted } else { self.remindersAllowed = granted }
                self.refresh(reloadReminders: true)
                self.notify()
            }
        }
        if #available(macOS 14.0, *) {
            if type == .event { store.requestFullAccessToEvents(completion: done) }
            else { store.requestFullAccessToReminders(completion: done) }
        } else {
            store.requestAccess(to: type, completion: done)
        }
    }

    private static func authorized(for type: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    @objc private func storeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh(reloadReminders: true)
            self?.notify()
        }
    }

    /// Reminders come back asynchronously: read every few minutes, and
    /// whenever the store says something changed; observers hear when they land.
    func refresh(reloadReminders: Bool = false) {
        start()
        guard remindersAllowed, !readingReminders,
              reloadReminders || Date().timeIntervalSince(remindersReadAt) > 300 else { return }
        readingReminders = true
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: Date().addingTimeInterval(-7 * 24 * 3600),
            ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingReminders = false
                self.remindersReadAt = Date()
                self.reminders = found ?? []
                self.notify()
            }
        }
    }

    func entries() -> [Entry] {
        let now = Date()
        var list: [Entry] = []
        if eventsAllowed {
            var events = readEvents(from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(Self.nearHorizon))
            if events.isEmpty {
                // Nothing this month: the next one further out, read hourly.
                if now.timeIntervalSince(farEventsReadAt) > 3600 {
                    farEventsReadAt = now
                    farEvents = Array(readEvents(from: now, to: now.addingTimeInterval(Self.farHorizon)).prefix(12))
                }
                events = farEvents.filter { ($0.end ?? $0.date) > now }
            }
            list += events
        }
        for reminder in reminders {
            // In the reminder's own calendar (Gregorian): the Mac's may be
            // Buddhist, which reads 2026 as 2026 BE — long past.
            guard let comps = reminder.dueDateComponents,
                  let due = comps.date ?? Calendar(identifier: .gregorian).date(from: comps) else { continue }
            var entry = Entry(title: reminder.title ?? "Reminder", date: due, end: nil,
                              isReminder: true, calendarColor: reminder.calendar?.color)
            entry.allDay = comps.hour == nil
            list.append(entry)
        }
        return list.sorted { $0.date < $1.date }
    }

    private func readEvents(from start: Date, to end: Date) -> [Entry] {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.endDate > now, event.status != .canceled else { return nil }
            // Invitations turned down don't count.
            if let me = event.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined { return nil }
            return Entry(title: event.title ?? "Event", date: event.startDate,
                         end: event.endDate, isReminder: false, calendarColor: event.calendar?.color)
        }.sorted { $0.date < $1.date }
    }

    /// What to show: an event under way first, else the soonest coming up;
    /// an overdue reminder only when nothing else is ahead.
    func next(in list: [Entry]? = nil) -> Entry? {
        let list = list ?? entries()
        let now = Date()
        if let current = list.first(where: { !$0.isReminder && $0.date <= now && ($0.end ?? now) > now }) {
            return current
        }
        // A day-only reminder counts for the whole of its day.
        let today = Calendar.current.startOfDay(for: now)
        return list.first { $0.date > now || ($0.allDay && $0.date >= today) }
            ?? list.last { $0.isReminder && $0.date <= now }
    }

    /// Under way, or starting (due) within the hour.
    static func isSoon(_ entry: Entry) -> Bool {
        guard !entry.allDay else { return false }
        let now = Date()
        if !entry.isReminder, entry.date <= now { return (entry.end ?? now) > now }
        return entry.date > now && entry.date.timeIntervalSince(now) <= 3600
    }

    /// "2 hr 14 min", "14 min left", "overdue", "tomorrow"…
    static func timeText(for entry: Entry) -> String {
        let now = Date()
        if entry.allDay {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                       to: entry.date).day ?? 0
            return days < 0 ? "overdue" : days == 0 ? "today" : days == 1 ? "tomorrow" : "\(days) d"
        }
        if !entry.isReminder, entry.date <= now, let end = entry.end {
            return duration(end.timeIntervalSince(now)) + " left"
        }
        if entry.date <= now { return "overdue" }
        return duration(entry.date.timeIntervalSince(now))
    }

    /// "2 hr 14 min", "2 hr", "14 min", "now"; a day or more "1 d 3 hr",
    /// a week or more "9 d".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes > 0 else { return "now" }
        if minutes >= 24 * 60 {
            let d = minutes / (24 * 60), h = (minutes % (24 * 60)) / 60
            return d >= 7 || h == 0 ? "\(d) d" : "\(d) d \(h) hr"
        }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    static func openApp(reminders: Bool) {
        let path = reminders ? "/System/Applications/Reminders.app" : "/System/Applications/Calendar.app"
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }
}
