import AppKit
import CoreAudio
import EventKit
import SwiftUI

// MARK: - The notch card's other pages
//
// Besides the combined AI page, the notch card pages through the next
// three days of Calendar, what you've copied lately, and the sound devices.
// Calendar also completes Reminders. The other pages have controls built from
// AppKit views that take the first click: the card's window is never key, and
// SwiftUI controls there can swallow it.

// MARK: Page dots

/// One dot per page under the notch, the current one stretched into a pill.
/// `progress` is a fractional page index, so mid-change the pill flows from
/// one dot into the next and the row keeps its width.
final class NotchPageDots: NSView {
    private static let dot: CGFloat = 6
    private static let pill: CGFloat = 18
    private static let gap: CGFloat = 6

    var count: Int { didSet { if count != oldValue { rebuild() } } }
    var progress: CGFloat = 0 { didSet { place() } }
    private var dots: [CALayer] = []

    var naturalWidth: CGFloat {
        CGFloat(count) * Self.dot + (Self.pill - Self.dot) + CGFloat(max(0, count - 1)) * Self.gap
    }

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        dots.forEach { $0.removeFromSuperlayer() }
        dots = (0..<count).map { _ in
            let dot = CALayer()
            dot.cornerRadius = Self.dot / 2
            layer?.addSublayer(dot)
            return dot
        }
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x = ((bounds.width - naturalWidth) / 2).rounded()
        for (index, dot) in dots.enumerated() {
            let weight = max(0, 1 - abs(progress - CGFloat(index)))
            let width = Self.dot + (Self.pill - Self.dot) * weight
            dot.frame = CGRect(x: x, y: ((bounds.height - Self.dot) / 2).rounded(), width: width, height: Self.dot)
            dot.backgroundColor = NSColor(white: 1, alpha: 0.3 + 0.7 * weight).cgColor
            x += width + Self.gap
        }
        CATransaction.commit()
    }

    /// The page whose dot is nearest `point` (this view's coordinates), when it's on the row.
    func index(at point: CGPoint) -> Int? {
        let row = CGRect(x: (bounds.width - naturalWidth) / 2, y: 0, width: naturalWidth, height: bounds.height)
        guard row.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return dots.indices.min { abs(dots[$0].frame.midX - point.x) < abs(dots[$1].frame.midX - point.x) }
    }
}

// MARK: - Calendar

/// The next three days from Calendar. Access is asked for the first time the
/// page is opened, not at launch.
final class NotchCalendar {
    static let shared = NotchCalendar()

    struct Event: Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
    }

    struct Day: Hashable {
        let date: Date
        let events: [Event]
    }

    struct Reminder: Identifiable {
        let id: String
        let title: String
        let due: Date?
        let allDay: Bool
        let list: String
        let color: NSColor
        var isCompleted = false
    }

    enum Access { case granted, denied, unknown }

    private let store = EKEventStore()
    private var observers: [() -> Void] = []
    private var asked = false
    private var askedReminders = false
    private var readingReminders = false
    private var remindersDirty = false
    private var remindersReadAt = Date.distantPast
    private var reminderObjects: [String: EKReminder] = [:]
    private var completingReminders: [String: Reminder] = [:]
    private(set) var reminders: [Reminder] = []
    private(set) var remindersError: String?
    var isLoadingReminders: Bool { readingReminders && remindersReadAt == .distantPast }

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refreshReminders(force: true)
            self?.observers.forEach { $0() }
        }
    }

    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }

    var access: Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return .unknown }
        if #available(macOS 14.0, *) { return status == .fullAccess ? .granted : .denied }
        return status == .authorized ? .granted : .denied
    }

    var remindersAccess: Access {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { return .unknown }
        if #available(macOS 14.0, *) { return status == .fullAccess ? .granted : .denied }
        return status == .authorized ? .granted : .denied
    }

    func requestRemindersAccessIfNeeded() {
        guard remindersAccess == .unknown, !askedReminders else { refreshReminders(); return }
        askedReminders = true
        let done: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshReminders(force: true)
                self?.observers.forEach { $0() }
            }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToReminders(completion: done) }
        else { store.requestAccess(to: .reminder, completion: done) }
    }

    func refreshReminders(force: Bool = false) {
        guard remindersAccess == .granted else {
            reminders = []
            return
        }
        if readingReminders { remindersDirty = remindersDirty || force; return }
        guard force || Date().timeIntervalSince(remindersReadAt) >= 60 else { return }
        readingReminders = true
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingReminders = false
                if self.remindersAccess == .granted {
                    let unfinished = (found ?? []).filter { !$0.isCompleted }
                    self.reminderObjects = Dictionary(unfinished.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { _, new in new })
                    let pending = Array(self.completingReminders.values)
                    self.reminders = (unfinished.filter { self.completingReminders[$0.calendarItemIdentifier] == nil }.map {
                        let components = $0.dueDateComponents
                        let due = components.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }
                        return Reminder(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: due,
                                        allDay: components?.hour == nil, list: $0.calendar?.title ?? "",
                                        color: $0.calendar?.color ?? .systemOrange)
                    } + pending).sorted {
                        if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                } else { self.reminders = []; self.reminderObjects = [:] }
                self.remindersReadAt = Date()
                self.observers.forEach { $0() }
                if self.remindersDirty {
                    self.remindersDirty = false
                    self.refreshReminders(force: true)
                }
            }
        }
    }

    func completeReminder(_ id: String) {
        guard completingReminders[id] == nil else { return }
        guard remindersAccess == .granted else {
            remindersError = "Reminders access is off. Enable it in System Settings."
            observers.forEach { $0() }
            return
        }
        guard let reminder = reminderObjects[id] ?? (store.calendarItem(withIdentifier: id) as? EKReminder) else {
            remindersError = "This reminder is no longer available. Refreshing…"
            refreshReminders(force: true)
            observers.forEach { $0() }
            return
        }
        guard !reminder.isCompleted else { return }
        let oldDate = reminder.completionDate
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            remindersError = nil
            if let index = reminders.firstIndex(where: { $0.id == id }) {
                reminders[index].isCompleted = true
                completingReminders[id] = reminders[index]
            }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                observers.forEach { $0() }
            }
            // Keep the confirmed checkmark visible before collapsing its row.
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.15 : 0.3)) { [weak self] in
                guard let self else { return }
                self.completingReminders.removeValue(forKey: id)
                self.reminderObjects.removeValue(forKey: id)
                self.reminders.removeAll { $0.id == id }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    self.observers.forEach { $0() }
                }
                self.refreshReminders(force: true)
            }
            return
        } catch {
            reminder.isCompleted = false
            reminder.completionDate = oldDate
            remindersError = "Couldn’t complete the reminder. Please try again."
        }
        observers.forEach { $0() }
    }

    func requestAccessIfNeeded() {
        guard access == .unknown, !asked else { return }
        asked = true
        let done: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.observers.forEach { $0() } }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    func days(_ count: Int = 3, now: Date = Date()) -> [Day] {
        guard access == .granted else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let events = store.events(matching: store.predicateForEvents(withStart: day, end: next, calendars: nil))
                .filter { $0.status != .canceled }
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
                .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate,
                             end: $0.endDate, allDay: $0.isAllDay, color: $0.calendar?.color ?? .systemBlue) }
            return Day(date: day, events: events)
        }
    }
}

/// A real AppKit button accepts the first click in the nonactivating notch panel.
final class NotchReminderButton: NSButton {
    var onPress: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { onPress?() }
}

struct NotchReminderCheck: NSViewRepresentable {
    let title: String
    let color: NSColor
    var isCompleted = false
    let onPress: () -> Void
    func makeNSView(context: Context) -> NotchReminderButton { NotchReminderButton() }
    func updateNSView(_ button: NotchReminderButton, context: Context) {
        button.contentTintColor = color
        button.image = NSImage(systemSymbolName: isCompleted ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        button.isEnabled = !isCompleted
        button.setAccessibilityLabel(isCompleted ? "Completed \(title)" : "Complete \(title)")
        button.onPress = onPress
    }
}

/// Three columns, one per day, divided like the Usage page's providers.
struct NotchCalendarView: View {
    let days: [NotchCalendar.Day]
    let access: NotchCalendar.Access
    let width: CGFloat
    var reminders: [NotchCalendar.Reminder] = []
    var remindersAccess: NotchCalendar.Access = .unknown
    var remindersLoading = false
    var remindersError: String?
    var onCompleteReminder: ((String) -> Void)?
    var now = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let maxEvents = 5
    private static let dividerSpace: CGFloat = 24
    private var columnWidth: CGFloat { (width - 48 - 2 * Self.dividerSpace) / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Group {
            switch access {
            case .granted:
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5)
                                .padding(.horizontal, (Self.dividerSpace - 0.5) / 2)
                        }
                        column(day, index: index).frame(width: columnWidth, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            case .unknown:
                message("Allow Calendar access to see the next three days here.")
            case .denied:
                message("Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars.")
            }
            }
            Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
            reminderSection
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reminders").font(.system(size: 16, weight: .semibold))
            switch remindersAccess {
            case .unknown:
                message("Allow Reminders access to see your unfinished reminders here.")
            case .denied:
                message("Reminders access is off. Turn it on in System Settings › Privacy & Security › Reminders.")
            case .granted:
                if remindersLoading { message("Loading reminders…") }
                else if reminders.isEmpty { message("No unfinished reminders") }
                ForEach(reminders) { reminder in
                    HStack(alignment: .center, spacing: 12) {
                        NotchReminderCheck(title: reminder.title, color: reminder.color, isCompleted: reminder.isCompleted) {
                            onCompleteReminder?(reminder.id)
                        }.frame(width: 24, height: 30)
                            .scaleEffect(reminder.isCompleted && !reduceMotion ? 1.12 : 1)
                            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55), value: reminder.isCompleted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reminder.title.isEmpty ? "Untitled" : reminder.title)
                                .strikethrough(reminder.isCompleted)
                                .font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                            Text(reminder.list).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if let due = reminder.due {
                            Text(Self.reminderDate(due, allDay: reminder.allDay))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Self.isOverdue(reminder, now: now) ? Color.red : .secondary)
                        }
                    }
                    .opacity(reminder.isCompleted ? 0.55 : 1)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
                if let remindersError { message(remindersError) }
            }
        }
    }

    static func isOverdue(_ reminder: NotchCalendar.Reminder, now: Date) -> Bool {
        guard let due = reminder.due else { return false }
        return due < (reminder.allDay ? Calendar.current.startOfDay(for: now) : now)
    }

    private static func reminderDate(_ due: Date, allDay: Bool) -> String {
        let date = dayMonth.string(from: due)
        return allDay ? date : "\(date) · \(clock.string(from: due))"
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }

    private func column(_ day: NotchCalendar.Day, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.name(day.date, index: index)).font(.system(size: 16, weight: .bold))
                Text(Self.dayMonth.string(from: day.date)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if day.events.isEmpty {
                Text("No events").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            ForEach(day.events.prefix(Self.maxEvents), id: \.id) { row($0) }
            if day.events.count > Self.maxEvents {
                Text("+\(day.events.count - Self.maxEvents) more")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ event: NotchCalendar.Event) -> some View {
        let past = !event.allDay && event.end <= now
        let live = !event.allDay && event.start <= now && now < event.end
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.color)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Untitled" : event.title)
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(Self.time(event))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(live ? Color(nsColor: event.color) : .secondary)
            }
        }
        .opacity(past ? 0.45 : 1)
    }

    private static func name(_ date: Date, index: Int) -> String {
        switch index {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return weekday.string(from: date)
        }
    }

    private static func time(_ event: NotchCalendar.Event) -> String {
        event.allDay ? "All day" : "\(clock.string(from: event.start)) – \(clock.string(from: event.end))"
    }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Clipboard history

/// What was copied lately, newest first, kept in memory only (never written to
/// disk) and cleared when MSG quits. Password managers mark their copies as
/// concealed or transient; those are left out. macOS has no notification for
/// the clipboard, so its change count is checked a few times a second while
/// the screen can be seen; that read is a single integer.
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    struct Item {
        enum Kind { case text, link, image, files }
        let id = UUID()
        let kind: Kind
        /// The text itself, a link, or a short description.
        let text: String
        let urls: [URL]
        let image: Data?
        let thumbnail: NSImage?
        let copiedAt: Date

        func sameContent(as other: Item) -> Bool {
            kind == other.kind && text == other.text && urls == other.urls && image == other.image
        }
    }

    private(set) var items: [Item] = []
    private var observers: [() -> Void] = []
    private var timer: Timer?
    private var running = false
    private var lastChange = NSPasteboard.general.changeCount

    private static let limit = 30
    private static let checkInterval: TimeInterval = 0.75
    /// nspasteboard.org markers, and 1Password's own.
    private static let markers: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]
    private static let maxText = 200_000
    private static let maxImage = 12_000_000

    private init() {}

    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }

    func start() {
        guard !running else { return }
        running = true
        PresentationState.shared.addObserver { [weak self] in self?.updateTimer() }
        updateTimer()
    }

    func stop() {
        running = false
        updateTimer()
    }

    private func updateTimer() {
        guard running, PresentationState.shared.canPresent else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        check()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.markers), let item = Self.read(board) else { return }
        // Copied again: back to the top rather than listed twice.
        items.removeAll { $0.sameContent(as: item) }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        observers.forEach { $0() }
    }

    private static func read(_ board: NSPasteboard) -> Item? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return Item(kind: .files, text: urls.map(\.lastPathComponent).joined(separator: ", "), urls: urls,
                        image: nil, thumbnail: NSWorkspace.shared.icon(forFile: urls[0].path), copiedAt: Date())
        }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff), data.count <= maxImage,
           let image = NSImage(data: data) {
            return Item(kind: .image, text: "Image \(Int(image.size.width)) × \(Int(image.size.height))", urls: [],
                        image: data, thumbnail: image, copiedAt: Date())
        }
        if let string = board.string(forType: .string), string.count <= maxText {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return Item(kind: .link, text: trimmed, urls: [url], image: nil, thumbnail: nil, copiedAt: Date())
            }
            return Item(kind: .text, text: string, urls: [], image: nil, thumbnail: nil, copiedAt: Date())
        }
        return nil
    }

    /// Puts `item` back on the clipboard; the next check moves it to the top.
    func restore(_ item: Item) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .files:
            board.writeObjects(item.urls as [NSURL])
        case .image:
            guard let data = item.image else { return }
            let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            board.setData(data, forType: png ? .png : .tiff)
        case .link:
            board.setString(item.text, forType: .string)
            board.setString(item.text, forType: .URL)
        case .text:
            board.setString(item.text, forType: .string)
        }
    }
}

/// Two columns of cards, newest first. Images fit inside a large preview;
/// longer text wraps. The grid scrolls when it exceeds the notch's viewport.
final class NotchClipboardPane: NSView {
    var onContentChanged: (() -> Void)?

    private static let padding: CGFloat = 24
    private static let cardHeight: CGFloat = 184
    private static let gap: CGFloat = 12
    private static let shown = 10

    private var rows: [NotchClipboardRow] = []
    private let scroll = NSScrollView()
    private let grid = NotchClipboardGrid()
    private let empty = NSTextField(labelWithString: "Nothing copied yet. What you copy shows here.")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = grid
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = NSColor(white: 1, alpha: 0.55)
        addSubview(empty)
        ClipboardHistory.shared.addObserver { [weak self] in
            self?.reload()
            self?.onContentChanged?()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows = ClipboardHistory.shared.items.prefix(Self.shown).map { item in
            let row = NotchClipboardRow(item: item)
            row.onClick = { ClipboardHistory.shared.restore(item) }
            grid.addSubview(row)
            return row
        }
        empty.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        needsLayout = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return Self.padding * 2 + 18 }
        let count = CGFloat((rows.count + 1) / 2)
        return Self.padding * 2 + count * Self.cardHeight + (count - 1) * Self.gap
    }

    override func layout() {
        super.layout()
        empty.frame = CGRect(x: Self.padding, y: Self.padding, width: bounds.width - 2 * Self.padding, height: 18)
        scroll.frame = bounds
        let contentHeight = fittingHeight(width: bounds.width)
        scroll.hasVerticalScroller = contentHeight > bounds.height
        grid.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: max(contentHeight, scroll.contentSize.height))
        let columnWidth = max(0, (grid.bounds.width - 2 * Self.padding - Self.gap) / 2)
        for (index, row) in rows.enumerated() {
            let column = CGFloat(index % 2), line = CGFloat(index / 2)
            row.frame = CGRect(x: Self.padding + column * (columnWidth + Self.gap),
                               y: Self.padding + line * (Self.cardHeight + Self.gap),
                               width: columnWidth, height: Self.cardHeight)
        }
    }
}

private final class NotchClipboardGrid: NSView {
    override var isFlipped: Bool { true }
}

final class NotchClipboardRow: NSView {
    var onClick: (() -> Void)?
    private let item: ClipboardHistory.Item
    private static let inset: CGFloat = 14
    private let icon = NSImageView()
    private let preview = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { updateBackground() } }
    private var copiedWork: DispatchWorkItem?

    override var isFlipped: Bool { true }

    init(item: ClipboardHistory.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        if item.kind == .files, let thumbnail = item.thumbnail {
            icon.image = thumbnail
        } else {
            let symbol = item.kind == .image ? "photo" : item.kind == .link ? "link" : "text.alignleft"
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.7)]))
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            icon.imageScaling = .scaleNone
        }
        text.stringValue = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        text.font = .systemFont(ofSize: 12.5)
        text.textColor = .white
        text.maximumNumberOfLines = 7
        text.cell?.wraps = true
        text.cell?.isScrollable = false
        text.lineBreakMode = .byTruncatingTail
        switch item.kind {
        case .image: title.stringValue = item.text
        case .text: title.stringValue = "Text"
        case .link: title.stringValue = "Link"
        case .files: title.stringValue = item.urls.count == 1 ? "File" : "\(item.urls.count) files"
        }
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.6)
        title.lineBreakMode = .byTruncatingTail
        preview.image = item.kind == .image ? item.thumbnail : nil
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        preview.isHidden = item.kind != .image
        text.isHidden = item.kind == .image
        age.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        age.alignment = .right
        showAge()
        for view in [icon, title, preview, text, age] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.text)
        setAccessibilityHelp("Click to copy this item again.")
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showAge() {
        let seconds = Int(Date().timeIntervalSince(item.copiedAt))
        age.stringValue = seconds < 60 ? "now" : seconds < 3600 ? "\(seconds / 60)m"
            : seconds < 86400 ? "\(seconds / 3600)h" : "\(seconds / 86400)d"
        age.textColor = NSColor(white: 1, alpha: 0.45)
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        icon.frame = CGRect(x: inset, y: inset, width: 16, height: 16)
        age.frame = CGRect(x: bounds.width - inset - 52, y: inset, width: 52, height: 16)
        title.frame = CGRect(x: inset + 24, y: inset,
                             width: max(0, bounds.width - 2 * inset - 24 - 60), height: 16)
        let content = CGRect(x: inset, y: inset + 28, width: max(0, bounds.width - 2 * inset),
                             height: max(0, bounds.height - 2 * inset - 28))
        preview.frame = content
        let textHeight = min(content.height, ceil(text.cell?.cellSize(forBounds: content).height ?? content.height))
        text.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: textHeight)
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.10 : 0.055).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: hovered ? 0.16 : 0.075).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        copyItem()
    }

    override func accessibilityPerformPress() -> Bool {
        copyItem()
        return true
    }

    private func copyItem() {
        onClick?()
        // Said in place of its age for a moment. (The list reorders on the
        // next clipboard check, which replaces this row.)
        age.stringValue = "Copied"
        age.textColor = .systemGreen
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showAge() }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

// MARK: - Music

private final class NotchMusicButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Track-change HUD: the same narrow body as volume/brightness, without a progress bar.
final class NotchCompactMusicPane: NSView {
    private let art = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let previous = NotchMusicButton(frame: .zero)
    private let play = NotchMusicButton(frame: .zero)
    private let next = NotchMusicButton(frame: .zero)
    private weak var pollingMonitor: MusicMonitor?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 7
        art.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .white
        artist.font = .systemFont(ofSize: 11)
        artist.textColor = NSColor(white: 1, alpha: 0.6)
        for field in [title, artist] { field.lineBreakMode = .byTruncatingTail }
        for (button, symbol, label, action) in [
            (previous, "backward.end.fill", "Previous track", #selector(previousTrack)),
            (play, "play.fill", "Play or pause", #selector(togglePlayback)),
            (next, "forward.end.fill", "Next track", #selector(nextTrack))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .white
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        for view in [art, title, artist, previous, play, next] as [NSView] { addSubview(view) }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pollingMonitor?.releasePolling() }

    func setPresented(_ presented: Bool) {
        let monitor = presented ? MusicMonitor.shared : nil
        if pollingMonitor !== monitor {
            pollingMonitor?.releasePolling()
            pollingMonitor = monitor
            monitor?.retainPolling()
        }
        reload()
    }

    func reload() {
        let monitor = MusicMonitor.shared
        art.image = monitor?.albumArt ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        title.stringValue = monitor?.currentTitle ?? "Not playing"
        title.toolTip = monitor?.currentTitle
        artist.stringValue = monitor?.currentArtist ?? monitor?.currentSource ?? ""
        play.image = NSImage(systemSymbolName: monitor?.isPlaying == true ? "pause.fill" : "play.fill",
                             accessibilityDescription: "Play or pause")
    }

    override func layout() {
        super.layout()
        art.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let controlsX = max(56, bounds.width - 96)
        title.frame = CGRect(x: 56, y: 4, width: max(0, controlsX - 68), height: 18)
        artist.frame = CGRect(x: 56, y: 25, width: max(0, controlsX - 68), height: 16)
        previous.frame = CGRect(x: controlsX, y: 8, width: 28, height: 28)
        play.frame = CGRect(x: controlsX + 32, y: 6, width: 32, height: 32)
        next.frame = CGRect(x: controlsX + 68, y: 8, width: 28, height: 28)
    }
    @objc private func togglePlayback() { MusicMonitor.shared?.togglePlayPause() }
    @objc private func previousTrack() { MusicMonitor.shared?.previousTrack() }
    @objc private func nextTrack() { MusicMonitor.shared?.nextTrack() }
}

private final class NotchMusicProgress: NSView {
    var value: Double = 0 { didSet { needsLayout = true } }
    private let fill = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.masksToBounds = true
        fill.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
        layer?.addSublayer(fill)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Playback progress")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(value.isFinite ? max(0, min(1, value)) : 0),
                            height: bounds.height)
        CATransaction.commit()
        setAccessibilityValue("\(Int((value.isFinite ? max(0, min(1, value)) : 0) * 100))%")
    }
}

/// Shares MSG's existing Now Playing monitor; polling runs only while this
/// page is presented. Controls work on the notch's nonactivating panel.
final class NotchMusicPane: NSView {
    private let art = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let previous = NotchMusicButton(frame: .zero)
    private let play = NotchMusicButton(frame: .zero)
    private let next = NotchMusicButton(frame: .zero)
    private let progress = NotchMusicProgress()
    private weak var observedMonitor: MusicMonitor?
    private weak var pollingMonitor: MusicMonitor?
    private var timer: Timer?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 12
        art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        artist.font = .systemFont(ofSize: 12)
        artist.textColor = NSColor(white: 1, alpha: 0.7)
        source.font = .systemFont(ofSize: 11.5, weight: .medium)
        source.textColor = NSColor(white: 1, alpha: 0.45)
        for field in [title, artist, source] { field.lineBreakMode = .byTruncatingTail }
        for (button, symbol, label, action) in [
            (previous, "backward.end.fill", "Previous track", #selector(previousTrack)),
            (play, "play.fill", "Play or pause", #selector(togglePlayback)),
            (next, "forward.end.fill", "Next track", #selector(nextTrack))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .white
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        for view in [art, title, artist, source, previous, play, next, progress] as [NSView] { addSubview(view) }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        pollingMonitor?.releasePolling()
    }

    func fittingHeight(width: CGFloat) -> CGFloat { 160 }

    func setPresented(_ presented: Bool) {
        if presented, let monitor = MusicMonitor.shared {
            if pollingMonitor !== monitor {
                pollingMonitor?.releasePolling()
                pollingMonitor = monitor
                monitor.retainPolling()
            }
            if timer == nil {
                let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
                tick.tolerance = 0.2
                RunLoop.main.add(tick, forMode: .common)
                timer = tick
            }
            reload()
        } else {
            timer?.invalidate()
            timer = nil
            pollingMonitor?.releasePolling()
            pollingMonitor = nil
        }
    }

    func reload() {
        let monitor = MusicMonitor.shared
        if let monitor, observedMonitor !== monitor {
            observedMonitor = monitor
            monitor.addObserver { [weak self] in self?.reload() }
        }
        let hasTrack = monitor?.currentTitle != nil
        title.stringValue = monitor?.currentTitle ?? "Not playing"
        title.toolTip = monitor?.currentTitle
        artist.stringValue = monitor?.currentArtist ?? ""
        source.stringValue = monitor?.currentSource ?? "Now Playing"
        art.image = (hasTrack ? monitor?.albumArt : nil)
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album artwork")
        play.image = NSImage(systemSymbolName: monitor?.isPlaying == true ? "pause.fill" : "play.fill",
                             accessibilityDescription: "Play or pause")
        for button in [previous, play, next] { button.isEnabled = monitor != nil }
        progress.value = monitor?.progress ?? 0
    }

    override func layout() {
        super.layout()
        art.frame = CGRect(x: 24, y: 24, width: 112, height: 112)
        let x: CGFloat = 160
        let width = max(0, bounds.width - x - 24)
        title.frame = CGRect(x: x, y: 24, width: max(0, width - 160), height: 22)
        artist.frame = CGRect(x: x, y: 50, width: max(0, width - 160), height: 18)
        source.frame = CGRect(x: x, y: 72, width: max(0, width - 160), height: 17)
        let controlsX = max(x, bounds.width - 24 - 136)
        let controlsCenter = art.frame.midY
        previous.frame = CGRect(x: controlsX, y: controlsCenter - 16, width: 32, height: 32)
        play.frame = CGRect(x: controlsX + 48, y: controlsCenter - 20, width: 40, height: 40)
        next.frame = CGRect(x: controlsX + 104, y: controlsCenter - 16, width: 32, height: 32)
        progress.frame = CGRect(x: x, y: 133, width: width, height: 3)
    }

    @objc private func togglePlayback() { MusicMonitor.shared?.togglePlayPause() }
    @objc private func previousTrack() { MusicMonitor.shared?.previousTrack() }
    @objc private func nextTrack() { MusicMonitor.shared?.nextTrack() }
}

// MARK: - Audio

/// A device's volume through CoreAudio: the whole device, else the average of
/// its front channels, in either direction.
enum DeviceVolume {
    private static func address(_ scope: AudioObjectPropertyScope, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
    }

    static func defaultDevice(_ direction: AudioDeviceRouting.Direction) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: direction.defaultSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func get(_ device: AudioDeviceID, _ direction: AudioDeviceRouting.Direction) -> Float? {
        var values: [Float] = []
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(direction.scope, element)
            var value = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { continue }
            if element == kAudioObjectPropertyElementMain { return value }
            values.append(value)
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    @discardableResult
    static func set(_ device: AudioDeviceID, _ direction: AudioDeviceRouting.Direction, to value: Float) -> Bool {
        var done = false
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(direction.scope, element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
            var level = max(0, min(1, value))
            done = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &level) == noErr || done
            if element == kAudioObjectPropertyElementMain && done { return true }
        }
        return done
    }
}

/// Output and input side by side: each with its level, which can be dragged,
/// and its devices, which can be picked.
final class NotchAudioPane: NSView {
    var onContentChanged: (() -> Void)?

    private static let padding: CGFloat = 24
    private static let columnGap: CGFloat = 24
    private let output = NotchAudioColumn(direction: .output)
    private let input = NotchAudioColumn(direction: .input)
    private let divider = NSView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        for column in [output, input] {
            column.onChanged = { [weak self] in
                self?.needsLayout = true
                self?.onContentChanged?()
            }
            addSubview(column)
        }
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        output.reload()
        input.reload()
        needsLayout = true
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        Self.padding * 2 + max(output.fittingHeight, input.fittingHeight)
    }

    /// The volume changed by key while this page shows: its own bar moves.
    func refreshOutputLevel() {
        output.showLevel(animated: true)
    }

    override func layout() {
        super.layout()
        let width = (bounds.width - 2 * Self.padding - Self.columnGap) / 2
        let height = max(output.fittingHeight, input.fittingHeight)
        output.frame = CGRect(x: Self.padding, y: Self.padding, width: width, height: height)
        input.frame = CGRect(x: Self.padding + width + Self.columnGap, y: Self.padding, width: width, height: height)
        divider.frame = CGRect(x: Self.padding + width + Self.columnGap / 2 - 0.25, y: Self.padding,
                               width: 0.5, height: height)
    }
}

final class NotchAudioColumn: NSView {
    var onChanged: (() -> Void)?

    private let direction: AudioDeviceRouting.Direction
    private let title = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let bar = NotchLevelBar()
    private let value = NSTextField(labelWithString: "")
    private var rows: [NotchHUDRow] = []
    private static let rowHeight: CGFloat = 26
    /// Rows' hover highlight reaches this far past their contents.
    private static let inset: CGFloat = 8

    override var isFlipped: Bool { true }

    init(direction: AudioDeviceRouting.Direction) {
        self.direction = direction
        super.init(frame: .zero)
        title.stringValue = direction == .output ? "Output" : "Input"
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.55)
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignLeft
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        value.textColor = .white
        value.alignment = .right
        bar.onChange = { [weak self] level, final in self?.drag(to: level, final: final) }
        for view in [title, icon, bar, value] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var fittingHeight: CGFloat { 16 + 12 + 22 + 10 + CGFloat(rows.count) * Self.rowHeight }

    func reload() {
        let snapshot = AudioDeviceRouting.snapshot(direction)
        let levels = NotchHUD.shared.levels
        rows.forEach { $0.removeFromSuperview() }
        rows = snapshot.devices.map { device in
            let kind = direction == .output ? (levels?.audioOutputKind(for: device.id) ?? .speaker) : .speaker
            let row = NotchHUDRow(output: .init(uid: device.uid, name: device.name, kind: kind,
                                                selected: device.uid == snapshot.selectedUID),
                                  inset: Self.inset, icon: direction == .input ? Self.symbol("mic.fill", alpha: 0.7) : nil)
            row.onClick = { [weak self] in self?.select(device.uid) }
            addSubview(row)
            return row
        }
        showLevel()
        needsLayout = true
    }

    /// `animated` when the level moved by itself (a volume key) rather than
    /// under the pointer.
    func showLevel(animated: Bool = false) {
        var level: CGFloat?, muted = false
        if direction == .output, let state = MainActor.assumeIsolated({ NotchHUD.shared.levels?.outputState() }) {
            level = state.value
            muted = state.muted
            icon.image = IndicatorRenderer.systemHUDIcon(kind: .volume, value: state.value ?? 0, muted: muted,
                                                         audioOutputKind: state.kind, deviceIcons: true,
                                                         pointSize: 13, color: .white)
        } else if let device = DeviceVolume.defaultDevice(direction) {
            level = DeviceVolume.get(device, direction).map { CGFloat($0) }
            icon.image = Self.symbol(direction == .output ? "speaker.wave.2.fill" : "mic.fill", alpha: 1)
        }
        bar.isEnabled = level != nil
        bar.set(level ?? 0, muted: muted, animated: animated)
        value.stringValue = level.map { muted ? "Muted" : "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }

    private func drag(to level: CGFloat, final: Bool) {
        if direction == .output, NotchHUD.shared.levels != nil {
            _ = MainActor.assumeIsolated { NotchHUD.shared.levels?.setOutputVolume(level, final: final) }
        } else if let device = DeviceVolume.defaultDevice(direction) {
            DeviceVolume.set(device, direction, to: Float(level))
        }
        bar.set(level, muted: false, animated: false)
        value.stringValue = "\(Int((level * 100).rounded()))%"
        if final { showLevel() }
    }

    private func select(_ uid: String) {
        guard AudioDeviceRouting.select(direction, uid: uid) else { return }
        reload()
        onChanged?()
        // CoreAudio can take a moment to report the new default's level.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showLevel() }
    }

    private static func symbol(_ name: String, alpha: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: alpha)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override func layout() {
        super.layout()
        title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 16)
        icon.frame = CGRect(x: 0, y: 28, width: 24, height: 22)
        value.frame = CGRect(x: bounds.width - 48, y: 30, width: 48, height: 17)
        bar.frame = CGRect(x: 30, y: 28, width: bounds.width - 30 - 56, height: 22)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: -Self.inset, y: 60 + CGFloat(index) * Self.rowHeight,
                               width: bounds.width + 2 * Self.inset, height: Self.rowHeight)
        }
    }
}
