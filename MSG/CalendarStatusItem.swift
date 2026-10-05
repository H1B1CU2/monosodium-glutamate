import AppKit
import EventKit

/// The next thing on the calendar or the reminder list, in the menu bar:
/// "งานวิชา pharm pro - 2 hr 14 min" — the time until it starts (or is due).
/// An event under way shows the time it has left. It always shows the
/// soonest thing ahead, however far off.
@available(macOS 14.0, *)
final class CalendarStatusItem: NSObject, NSMenuDelegate {
    private let feed = CalendarFeed.shared
    private let statusItem: NSStatusItem
    private var timer: Timer?
    private var feedObserver: UUID?
    private static let titleFont = NSFont.systemFont(ofSize: 11)

    private typealias Entry = CalendarFeed.Entry

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.isVisible = false
        statusItem.button?.font = Self.titleFont
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        feedObserver = feed.addObserver { [weak self] in self?.render() }
        PresentationState.shared.addObserver { [weak self] in self?.updateTimer() }
        feed.start()
        updateTimer()
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        if let feedObserver { feed.removeObserver(feedObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Refresh

    /// Once a minute, on the minute, while there's a menu bar to see.
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard PresentationState.shared.canPresent else { return }
        refresh()
        let nextMinute = ceil(Date().timeIntervalSinceReferenceDate / 60) * 60
        let timer = Timer(fireAt: Date(timeIntervalSinceReferenceDate: nextMinute + 0.5), interval: 60,
                          target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() { refresh() }

    func refresh() {
        feed.refresh()
        render()
    }

    private func render() {
        guard let entry = feed.next() else {
            // Nothing ahead at all: just the calendar glyph.
            statusItem.button?.title = ""
            statusItem.button?.attributedTitle = NSAttributedString()
            statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Nothing coming up")
            statusItem.isVisible = true
            return
        }
        let time = CalendarFeed.timeText(for: entry)
        var title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = AppSettings.shared.calendarMaxTitleLength
        if cap > 0 && title.count > cap {
            title = String(title.prefix(cap - 1)) + "…"
        }
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: NSColor.controlTextColor
        ]))
        attr.append(NSAttributedString(string: "  ", attributes: [
            .font: Self.titleFont
        ]))
        attr.append(NSAttributedString(string: time, attributes: [
            .font: Self.titleFont,
            .foregroundColor: NSColor.controlTextColor.withAlphaComponent(0.55)
        ]))
        statusItem.button?.font = Self.titleFont
        statusItem.button?.attributedTitle = attr
        statusItem.button?.image = nil
        statusItem.isVisible = true
    }

    // MARK: Menu

    /// What's coming up next, and the apps to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        let upcoming = feed.entries().filter { ($0.end ?? $0.date) > now || $0.isReminder }
        if upcoming.isEmpty {
            let empty = NSMenuItem(title: "Nothing coming up", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in upcoming.prefix(12) {
            formatter.timeStyle = entry.allDay ? .none : .short
            let when = formatter.string(from: entry.date)
            let item = NSMenuItem(title: "\(when)  \(entry.title)", action: #selector(openSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.isReminder
            let symbol = entry.isReminder ? "checklist" : "circle.fill"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: entry.isReminder ? 11 : 7, weight: .regular)
                    .applying(.init(paletteColors: [entry.calendarColor ?? .secondaryLabelColor]))
                item.image = image.withSymbolConfiguration(config)
            }
            menu.addItem(item)
        }
        if !feed.eventsAllowed || !feed.remindersAllowed {
            menu.addItem(.separator())
            let access = NSMenuItem(title: "Allow Calendar & Reminders Access…", action: #selector(openPrivacy), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
        }
        menu.addItem(.separator())
        let calendar = NSMenuItem(title: "Open Calendar", action: #selector(openSource(_:)), keyEquivalent: "")
        calendar.target = self
        calendar.representedObject = false
        menu.addItem(calendar)
        let reminders = NSMenuItem(title: "Open Reminders", action: #selector(openSource(_:)), keyEquivalent: "")
        reminders.target = self
        reminders.representedObject = true
        menu.addItem(reminders)
    }

    @objc private func openSource(_ sender: NSMenuItem) {
        CalendarFeed.openApp(reminders: sender.representedObject as? Bool ?? false)
    }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
