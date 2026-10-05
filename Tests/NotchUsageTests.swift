import AppKit
import SwiftUI

// The test executable has no windows and uses the real card/dashboard views.
final class PresentationState {
    static let shared = PresentationState()
    let canPresent = true
    func addObserver(_ callback: @escaping () -> Void) {}
}
enum AgentLockScreen {
    struct Row: Equatable {
        let provider: AIProvider
        let count: Int
        let title: String?
        var sessions: [TokenBarSnapshot.WorkingSession] = []
        var quotaRemaining: Double? = nil
    }
}

// Unrelated panes are placeholders; the production AI view, page dots and
// notch host are compiled unchanged for these offscreen interaction checks.
final class NotchCalendar {
    enum Access { case unknown, granted, denied }
    struct Event: Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
    }
    struct Day: Hashable { let date: Date; let events: [Event] }
    struct Reminder: Identifiable {
        let id: String
        let title: String
        let due: Date?
        let allDay: Bool
        let list: String
        let color: NSColor
        var isCompleted = false
    }
    static let shared = NotchCalendar()
    var access = Access.unknown
    var remindersAccess = Access.granted
    var reminders = (0..<30).map {
        Reminder(id: "r\($0)", title: "Reminder \($0)", due: Date(), allDay: true, list: "Work", color: .orange)
    }
    var remindersError: String?
    var isLoadingReminders = false
    var completed: [String] = []
    func days() -> [Day] { [] }
    func addObserver(_ callback: @escaping () -> Void) {}
    func requestAccessIfNeeded() {}
    func requestRemindersAccessIfNeeded() {}
    func refreshReminders() {}
    func completeReminder(_ id: String) { completed.append(id) }
}
class TestNotchPane: NSView {
    var onContentChanged: (() -> Void)?
    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func reload() {}
    func fittingHeight(width: CGFloat) -> CGFloat { 100 }
}
final class NotchClipboardPane: TestNotchPane {}
final class NotchTrayPane: TestNotchPane {}
final class NotchAudioPane: TestNotchPane { func refreshOutputLevel() {} }
final class NotchMusicPane: TestNotchPane {
    func setPresented(_ presented: Bool) {}
}
struct NotchWingEvent { var link: AgentSessionLink? }
final class NotchWingIndicator: NSView {
    var event: NotchWingEvent?
    var drawnFrame: CGRect { frame }
    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ event: NotchWingEvent) { self.event = event }
}

@main
struct NotchUsageTests {
    @MainActor static func main() throws {
        var launcher = CortexNotchSession()
        launcher.open(id: "first", pid: 42, dashboardVisible: true)
        launcher.open(id: "first", pid: 42, dashboardVisible: false) // State handshake.
        launcher.open(id: "second", pid: 42, dashboardVisible: false) // Quick reopen.
        precondition(launcher.close(id: "first", resume: true) == nil)
        precondition(launcher.isActive && launcher.pid == 42)
        precondition(launcher.close(id: "second", resume: true) == true)
        precondition(!launcher.isActive && launcher.pid == nil)
        launcher.open(id: "locked", pid: 42, dashboardVisible: true)
        launcher.cancelResume()
        precondition(launcher.close(id: "locked", resume: true) == false)
        launcher.open(id: "outside", pid: 42, dashboardVisible: true)
        precondition(launcher.close(id: "outside", resume: false) == false)
        launcher.open(id: "idle", pid: 42, dashboardVisible: false)
        precondition(launcher.close(id: "idle", resume: true) == false)

        let json = """
        {"updatedAt":1790812800,"codex":{"enabled":true,"available":true,"sessionPercent":68},
         "deepseek":{"enabled":true,"available":true,"balance":3,"currency":"USD","balanceTHB":100},
         "usage":{"firstDayOfWeek":"monday","histories":{"codex":{"2026-09-28":10,"2026-10-01":20,"2026-09-27":999},"deepseek":{"2026-09-28":29.49}},
          "deepseekCurrency":"THB","billingPeriod":"Off-Peak","billingDetail":"50% lower rates", "billingTransitionAt":1790819000,
          "antigravityStatus":"language server not running"}}
        """
        let snapshot = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10))!
        let days = snapshot.usage!.days(for: .codex, now: now, calendar: calendar)!
        precondition(days.first!.label == "Mon" && days.last!.label == "Sun")
        precondition(days.reduce(0) { $0 + $1.value } == 30, "Exclude prior-week history across month boundaries")
        precondition(snapshot.usage!.days(for: .claude, now: now, calendar: calendar) == nil,
                     "Missing history stays unavailable rather than becoming zero usage")
        let sundayData = Data(json.replacingOccurrences(of: "monday", with: "sunday").utf8)
        let sunday = try JSONDecoder().decode(TokenBarSnapshot.self, from: sundayData)
        precondition(sunday.usage!.days(for: .codex, now: now, calendar: calendar)!.first!.label == "Sun")
        precondition(sunday.usage!.days(for: .codex, now: now, calendar: calendar)!.reduce(0) { $0 + $1.value } == 1029)
        let malformed = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data("{\"usage\":{\"histories\":\"bad\",\"billingTransitionAt\":\"bad\"}}".utf8))
        precondition(malformed.usage?.histories == nil && malformed.usage?.billingTransitionAt == nil)
        let legacy = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data("{\"codex\":{\"enabled\":true}}".utf8))
        precondition(legacy.usage == nil)
        precondition(NotchUsageText.reset(now.timeIntervalSince1970 + 4440, weekly: false, now: now) == "in 1 hr 14 min")
        precondition(NotchUsageText.reset(now.timeIntervalSince1970 - 1, weekly: false, now: now) == "ready")
        precondition(NotchUsageText.reset(nil, weekly: false, now: now) == "—")
        precondition(NotchUsageText.amount(29.49, currency: "THB") == "฿29.49")
        precondition(NotchUsageText.amount(418_400_000, currency: nil) == "418.4M")
        precondition(NotchTransition.windowLevel.rawValue > NSWindow.Level.statusBar.rawValue
                     && NotchTransition.windowLevel.rawValue < NSWindow.Level.popUpMenu.rawValue,
                     "The notch stays above control-bar covers and below menus")
        let large = CGRect(x: 416, y: 447, width: 680, height: 535)
        let small = CGRect(x: 416, y: 762, width: 680, height: 220)
        precondition(NotchTransition.canvas(from: large, to: small) == large
                     && NotchTransition.canvas(from: small, to: large) == large,
                     "Both directions use one fixed canvas with its top edge anchored")
        let bar = NotchUsageBarShape().path(in: CGRect(x: 0, y: 0, width: 12, height: 44))
        precondition(bar.contains(CGPoint(x: 0.1, y: 43.9)) && bar.contains(CGPoint(x: 11.9, y: 43.9))
                     && !bar.contains(CGPoint(x: 0.1, y: 0.1)), "Chart bars have flat bases and rounded tops")

        _ = NSApplication.shared
        AIUsageFeed.shared.apply(snapshot)
        let suiteName = "MSG.NotchUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let row = AgentLockScreen.Row(provider: .codex, count: 1, title: "Contract session",
                                     sessions: [.init(id: "one", title: "Contract session", since: now.timeIntervalSince1970,
                                                      activity: "Editing", completedSteps: 2, totalSteps: 4)], quotaRemaining: 32)
        let view = AgentNotchDashboardView(defaults: defaults)
        view.configureNotch(width: 185, height: 32, maximumHeight: 800)
        var changes = 0
        view.onPageChanged = { changes += 1; view.update(rows: [row], state: .working(since: now)) }
        view.update(rows: [row], state: .working(since: now))
        precondition(view.page == .usage && view.fittingCardSize.height > 100 && view.fittingCardSize.height <= 800)
        precondition(view.subviews.compactMap { $0 as? AgentActivityCardView }.isEmpty,
                     "Tasks belong to the combined page, with no separate task pane")
        let usagePane = view.subviews.compactMap { $0 as? NSScrollView }.first!
        let usage = usagePane.documentView as! NSHostingView<NotchUsageView>
        precondition(usage.rootView.rows == [row] && usage.rootView.expandedHistories.isEmpty)
        precondition(NotchAIContent.sessions(for: .claude, rows: [row]).isEmpty,
                     "Tasks never appear beneath the wrong provider")
        let fallback = AgentLockScreen.Row(provider: .claude, count: 2, title: "Legacy task")
        precondition(NotchAIContent.sessions(for: .claude, rows: [fallback]).first?.title == "Legacy task",
                     "Older snapshots retain their task title even without a session list")
        precondition(NotchAIContent.detail(row.sessions[0]) == "Editing · 2/4 steps")
        precondition(NotchAIContent.detail(.init(activity: "Editing", completedSteps: 5, totalSteps: 4)) == "Editing")
        precondition(NotchAIContent.title(.init(title: "  "), index: 1) == "Session 2")
        precondition(NotchAIContent.elapsed(since: now.timeIntervalSince1970 - 75, now: now) == "1m 15s")
        precondition(NotchAIContent.elapsed(since: .nan, now: now).isEmpty)
        let destination = TokenBarSnapshot.WorkingSession.Destination(url: "codex://threads/one", bundleID: "com.openai.codex")
        let clickable = AgentLockScreen.Row(provider: .codex, count: 2, title: "Same title", sessions: [
            .init(id: "one", title: "Same title", destination: destination),
            .init(id: "two", title: "Same title", destination: .init(url: nil, bundleID: "com.apple.Terminal"))])
        view.update(rows: [clickable], state: .working(since: now))
        NotchSessionMode.hitFrames = [
            .init(provider: .codex, sessionID: "one", frame: CGRect(x: 24, y: 48, width: 100, height: 24)),
            .init(provider: .codex, sessionID: "two", frame: CGRect(x: 24, y: 84, width: 100, height: 24))]
        let firstTask = view.convert(CGPoint(x: 50, y: 60), from: usage)
        let secondTask = view.convert(CGPoint(x: 50, y: 96), from: usage)
        let firstLink = view.sessionLink(at: firstTask)!
        precondition(firstLink.session == "one" && firstLink.destination == destination)
        precondition(view.sessionLink(at: secondTask)?.session == "two"
                     && view.sessionLink(at: secondTask)?.destination?.bundleID == "com.apple.Terminal",
                     "Matching titles open their own session or captured app")
        precondition(view.sessionLink(at: view.convert(CGPoint(x: 400, y: 60), from: usage)) == nil,
                     "A background click keeps the TokenBar popover action")
        var opened: [AgentSessionLink] = []
        view.onOpenSession = { opened.append($0) }
        usage.rootView.onOpenSession?(firstLink)
        precondition(opened == [firstLink], "Native button actions forward the exact destination once")
        view.update(rows: [row], state: .working(since: now))
        NotchSessionMode.hitFrames = [.init(provider: .codex, sessionID: "two", frame: CGRect(x: 24, y: 48, width: 100, height: 24))]
        precondition(view.sessionLink(at: firstTask) == nil, "A departed session cannot open through an old hit area")
        precondition(NotchAIContent.link(.init(id: "unknown-1"), provider: .codex).session == nil)
        NotchSessionMode.hitFrames = []
        let collapsedHeight = view.fittingCardSize.height
        var contentChanges = 0
        view.onContentChanged = { contentChanges += 1 }
        NotchHistoryMode.hitFrames = [.codex: CGRect(x: 24, y: 48, width: 100, height: 24)]
        let historyPoint = view.convert(CGPoint(x: 50, y: 60), from: usage)
        precondition(view.selectTab(at: historyPoint) && contentChanges == 1)
        precondition(usage.rootView.expandedHistories == [.codex] && view.fittingCardSize.height > collapsedHeight,
                     "Expanding a provider's graph grows the shared page and requests a window resize")
        view.refreshClock()
        precondition(usage.rootView.expandedHistories == [.codex], "Live refresh keeps the graph expanded")
        NotchHistoryMode.hitFrames = [.codex: CGRect(x: 24, y: 48, width: 100, height: 24)]
        precondition(view.selectTab(at: historyPoint) && usage.rootView.expandedHistories.isEmpty)
        precondition(view.fittingCardSize.height == collapsedHeight, "Collapsing restores the compact size")
        NotchHistoryMode.hitFrames = [:]
        NotchResetMode.hitFrames = []

        let dots = view.subviews.compactMap { $0 as? NotchPageDots }.first!
        precondition(dots.count == 6, "The combined AI page and Music each have one page")
        func dotPoint(_ index: Int) -> CGPoint {
            let start = (dots.bounds.width - dots.naturalWidth) / 2
            let x = index == 0 ? start + 3 : start + 24 + CGFloat(index - 1) * 12 + 3
            return view.convert(CGPoint(x: x, y: dots.bounds.midY), from: dots)
        }
        let initialSize = view.fittingCardSize
        let initialPage = view.page
        let storedPage = defaults.string(forKey: AgentNotchDashboardView.pageDefaultsKey)
        usagePane.contentView.scroll(to: CGPoint(x: 0, y: 12))
        let initialScroll = usagePane.contentView.bounds.origin
        let hud = NSView()
        let priorHost = NotchShapeHostView(content: hud)
        precondition(hud.alphaValue == 0, "Standalone hosts initially hide their content")
        hud.isHidden = true
        view.presentHUD(hud, size: CGSize(width: 345, height: 128))
        view.layoutSubtreeIfNeeded()
        precondition(hud.superview === view && !hud.isHidden && hud.alphaValue == 1,
                     "Borrowed HUD content must be visible after a standalone host hid it")
        precondition(priorHost.content === hud)
        precondition(view.isPresentingHUD && view.page == initialPage && usagePane.isHidden && dots.isHidden)
        precondition(view.fittingCardSize == CGSize(width: 345, height: 128))
        precondition(hud.frame.minX == (view.bounds.width - 345) / 2)
        precondition(!view.selectTab(at: dotPoint(2)), "Temporary controls cannot change the saved page")
        view.presentHUD(hud, size: CGSize(width: 345, height: 140))
        precondition(view.subviews.filter { $0 === hud }.count == 1)
        view.dismissHUD()
        view.layoutSubtreeIfNeeded()
        precondition(!view.isPresentingHUD && hud.superview == nil && !usagePane.isHidden && !dots.isHidden)
        precondition(view.fittingCardSize == initialSize && view.page == initialPage)
        precondition(usagePane.contentView.bounds.origin == initialScroll)
        precondition(defaults.string(forKey: AgentNotchDashboardView.pageDefaultsKey) == storedPage)
        let calendarPoint = dotPoint(2)
        precondition(view.selectTab(at: calendarPoint) && view.page == .calendar && changes == 1)
        precondition(view.selectTab(at: calendarPoint) && changes == 1)
        let calendarPane = view.subviews.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSHostingView<NotchCalendarView> }!
        let paneAnimation = usagePane.layer!.animation(forKey: "paneTransition") as! CAAnimationGroup
        precondition(!usagePane.isHidden && !calendarPane.isHidden && view.isPageTransitioning)
        precondition(paneAnimation.beginTime == view.pageTransitionStart
                     && paneAnimation.duration == NotchTransition.duration)
        let stableUsageFrame = usagePane.frame
        let stableCalendarFrame = calendarPane.frame
        view.setFrameSize(CGSize(width: view.bounds.width, height: 750))
        view.layoutSubtreeIfNeeded()
        precondition(usagePane.frame == stableUsageFrame && calendarPane.frame == stableCalendarFrame,
                     "Resizing the backing canvas keeps both pane viewports stable")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(view.selectionProgress > 0 && view.selectionProgress < 2)
        let interruptedProgress = view.selectionProgress
        precondition(view.selectTab(at: dotPoint(0)) && view.selectionProgress == interruptedProgress)
        RunLoop.main.run(until: Date().addingTimeInterval(NotchTransition.duration + 0.06))
        precondition(view.page == .usage && view.selectionProgress == 0)
        precondition(!usagePane.isHidden && calendarPane.isHidden && !view.isPageTransitioning)
        precondition(view.selectTab(at: calendarPoint))
        view.update(rows: [row], state: .working(since: now))
        view.prepareForPresentation()
        precondition(view.page == .calendar && view.selectionProgress == 2)
        view.layoutSubtreeIfNeeded()
        precondition(calendarPane.frame.minY == 46,
                     "The title ends at 46; the pane's own 24-point inset supplies the content gap")
        let calendarDocument = calendarPane.documentView as! NSHostingView<NotchCalendarView>
        precondition(calendarDocument.fittingSize.height > calendarPane.bounds.height, "All reminders can scroll")
        var presses = 0
        let reminderCheck = NSHostingView(rootView: NotchReminderCheck(title: "Test reminder", color: .orange) { presses += 1 }
            .frame(width: 24, height: 30))
        let buttonWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 24, height: 30),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        buttonWindow.contentView = reminderCheck
        reminderCheck.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func nativeButtons(in root: NSView) -> [NotchReminderButton] {
            root.subviews.flatMap { child in
                (child as? NotchReminderButton).map { [$0] } ?? nativeButtons(in: child)
            }
        }
        let completionButton = nativeButtons(in: reminderCheck).first!
        precondition(completionButton.acceptsFirstMouse(for: nil))
        completionButton.performClick(nil)
        precondition(presses == 1, "The native first-click button invokes completion exactly once")
        reminderCheck.rootView = NotchReminderCheck(title: "Test reminder", color: .orange, isCompleted: true) { presses += 1 }
            .frame(width: 24, height: 30)
        reminderCheck.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(nativeButtons(in: reminderCheck).first?.isEnabled == false,
                     "The checked row stays visible but cannot save the reminder twice")


        precondition(AgentNotchDashboardView(defaults: defaults).page == .calendar)
        defaults.set("sessions", forKey: AgentNotchDashboardView.pageDefaultsKey)
        precondition(AgentNotchDashboardView(defaults: defaults).page == .usage
                     && defaults.string(forKey: AgentNotchDashboardView.pageDefaultsKey) == "usage",
                     "Saved Tasks selections migrate to the combined AI page")
        defaults.set("invalid", forKey: AgentNotchDashboardView.pageDefaultsKey)
        precondition(AgentNotchDashboardView(defaults: defaults).page == .usage)

        let combined = AgentNotchDashboardView(defaults: defaults)
        combined.configureNotch(width: 220, height: 32, maximumHeight: 180)
        let manyTasks = AgentLockScreen.Row(provider: .codex, count: 20, title: nil,
                                           sessions: (0..<20).map { .init(title: "Task \($0)", activity: "Editing") })
        combined.update(rows: [manyTasks], state: .working(since: now))
        let constrainedScroll = combined.subviews.compactMap { $0 as? NSScrollView }.first!
        precondition(combined.fittingCardSize.height <= 180 && constrainedScroll.hasVerticalScroller,
                     "Many tasks remain reachable by scrolling within the display limit")
        let constrainedDocument = constrainedScroll.documentView!
        NotchHistoryMode.hitFrames = [.codex: CGRect(x: 24, y: 300, width: 100, height: 24)]
        let hiddenPoint = combined.convert(CGPoint(x: 50, y: 310), from: constrainedDocument)
        precondition(!combined.selectTab(at: hiddenPoint), "Controls below the viewport cannot catch clicks")
        NotchSessionMode.hitFrames = [.init(provider: .codex, sessionID: nil, frame: CGRect(x: 24, y: 300, width: 100, height: 24))]
        precondition(combined.sessionLink(at: hiddenPoint) == nil, "Hidden task rows cannot catch clicks")
        constrainedScroll.contentView.scroll(to: CGPoint(x: 0, y: 280))
        constrainedScroll.reflectScrolledClipView(constrainedScroll.contentView)
        let scrolledPoint = combined.convert(CGPoint(x: 50, y: 310), from: constrainedDocument)
        precondition(combined.selectTab(at: scrolledPoint), "History controls work after vertical scrolling")
        // History changes rebuild SwiftUI preferences; restore this task's test hit area.
        NotchSessionMode.hitFrames = [.init(provider: .codex, sessionID: nil, frame: CGRect(x: 24, y: 300, width: 100, height: 24))]
        precondition(combined.sessionLink(at: scrolledPoint)?.provider == .codex,
                     "A visible task opens its app after vertical scrolling")
        NotchSessionMode.hitFrames = []
        NotchHistoryMode.hitFrames = [:]
        NotchResetMode.hitFrames = []

        func usageHeight(antigravity: String?, rows: [AgentLockScreen.Row] = []) throws -> CGFloat {
            let extra = antigravity.map { ",\"antigravity\":\($0)" } ?? ""
            let fixture = try JSONDecoder().decode(TokenBarSnapshot.self,
                from: Data("{\"codex\":{\"enabled\":true,\"available\":true}\(extra)}".utf8))
            return NSHostingView(rootView: NotchUsageView(snapshot: fixture, stale: false, width: 680,
                                                       rows: rows)).fittingSize.height
        }
        let noAntigravity = try usageHeight(antigravity: nil)
        let unavailableHeight = try usageHeight(antigravity: "{\"enabled\":true,\"available\":false}")
        let disabledHeight = try usageHeight(antigravity: "{\"enabled\":false,\"available\":true}")
        precondition(unavailableHeight == noAntigravity && disabledHeight == noAntigravity)
        let agRow = AgentLockScreen.Row(provider: .antigravity, count: 1, title: "Live Gemini task")
        let unavailable = try JSONDecoder().decode(TokenBarSnapshot.self,
            from: Data("{\"antigravity\":{\"enabled\":true,\"available\":false}}".utf8))
        precondition(NotchAIContent.providers(snapshot: unavailable, rows: [agRow]) == [.antigravity],
                     "A live task remains visible even while its quota API is unavailable")
        let disabled = try JSONDecoder().decode(TokenBarSnapshot.self,
            from: Data("{\"antigravity\":{\"enabled\":false,\"available\":true}}".utf8))
        precondition(NotchAIContent.providers(snapshot: disabled, rows: [agRow]).isEmpty)
        let activeHeight = try usageHeight(antigravity: nil, rows: [row])
        precondition(activeHeight > noAntigravity,
                     "Live tasks contribute height inside the provider's existing section")

        defaults.set(["music", "calendar"], forKey: AgentNotchDashboardView.disabledPanesKey)
        defaults.set("calendar", forKey: AgentNotchDashboardView.pageDefaultsKey)
        let filtered = AgentNotchDashboardView(defaults: defaults)
        precondition(filtered.availablePages == [.usage, .clipboard, .tray, .audio] && filtered.page == .usage)
        precondition(filtered.subviews.compactMap { $0 as? NotchPageDots }.first?.count == 4)
        precondition(filtered.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "AI" },
                     "The top-left label names the current page")
        defaults.set(AgentNotchDashboardView.Page.allCases.map(\.rawValue), forKey: AgentNotchDashboardView.disabledPanesKey)
        filtered.prepareForPresentation()
        precondition(filtered.availablePages.isEmpty, "All panes may be switched off without inventing a fallback pane")
        defaults.removeObject(forKey: AgentNotchDashboardView.disabledPanesKey)

        let host = NotchCardHostView()
        host.frame = CGRect(origin: .zero, size: large.size)
        let notch = CGRect(x: large.midX - 92, y: large.maxY - 32, width: 184, height: 32)
        host.layout(notch: notch, in: large)
        host.showOpenInstantly()
        let start = CACurrentMediaTime()
        host.animateResize(to: small.size, notch: notch, in: large, beginTime: start)
        let silhouette = host.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }.first!
        let container = host.subviews.first!
        let contentMask = container.layer!.mask as! CAShapeLayer
        let resize = silhouette.animation(forKey: "paneResize") as! CABasicAnimation
        let maskResize = contentMask.animation(forKey: "paneResize") as! CABasicAnimation
        precondition(host.frame.size == large.size && host.card.frame.size == large.size,
                     "The backing surface stays fixed throughout the resize")
        precondition(resize.beginTime == start && maskResize.beginTime == start
                     && resize.duration == NotchTransition.duration,
                     "The silhouette and content clipping mask animate in lockstep")
        let fromPath = resize.fromValue as! CGPath
        let toPath = resize.toValue as! CGPath
        precondition(fromPath.boundingBoxOfPath.height == large.height
                     && toPath.boundingBoxOfPath.height == small.height
                     && fromPath.boundingBoxOfPath.maxY == toPath.boundingBoxOfPath.maxY,
                     "The compositor morphs the bottom edge while keeping the top stationary")
        precondition((maskResize.toValue as! CGPath) == toPath,
                     "Growing or shrinking never reveals content outside the silhouette")
        let interruptedSize = CGSize(width: 680, height: 350)
        host.layout(notch: notch, in: large, cardSize: interruptedSize)
        host.showOpenInstantly()
        host.animateResize(to: large.size, notch: notch, in: large, beginTime: start)
        let reversal = silhouette.animation(forKey: "paneResize") as! CABasicAnimation
        precondition((reversal.fromValue as! CGPath).boundingBoxOfPath.size == interruptedSize,
                     "A reversed transition resumes from its captured visible size")
        view.stopPageTransition()
        host.card.stopPageTransition()

        if CommandLine.arguments.count > 1 {
            let live = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(live.usage?.histories?["claude"] != nil && live.usage?.histories?["codex"] != nil
                         && live.usage?.histories?["deepseek"] != nil, "Installed TokenBar exports the shared history contract")
            precondition(live.usage?.billingTransitionAt != nil && live.usage?.deepseekCurrency != nil)
        }
        print("Combined AI tasks, graph controls, legacy pages, scrolling, history and transition checks passed")
    }
}
