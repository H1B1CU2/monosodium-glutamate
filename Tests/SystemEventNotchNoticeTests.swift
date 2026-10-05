import AppKit

final class AppSettings {
    static let shared = AppSettings()
    var notchAmphetamineNotice = false
    var notchDisplayNotice = false
    var notchWARPNotice = false
}
final class PresentationState {
    static let shared = PresentationState()
    func addObserver(_ observer: @escaping () -> Void) {}
}
final class NotchHUD {
    static let shared = NotchHUD()
    func showSystemEvent(_ event: SystemNotchEvent) -> Bool { true }
    func dismissSystemEvent(kind: SystemNotchEvent.Kind) {}
}

@main
struct SystemEventNotchNoticeTests {
    static func main() {
        var state = SystemStateChangeTracker()
        precondition(state.update(nil) == nil)
        precondition(state.update(true) == nil, "An already-active Amphetamine/WARP state is quiet at startup")
        precondition(state.update(true) == nil, "Repeated reads must not repeat a card")
        precondition(state.update(nil) == nil && state.latest == true, "Read failures must not invent an Off card")
        precondition(state.update(false) == false && state.update(false) == nil)
        precondition(state.update(true) == true, "The next confirmed session or connection produces On")
        let monitor = SystemDisplaySnapshot(id: "monitor-a", name: "MSI MP341CQ")
        let second = SystemDisplaySnapshot(id: "monitor-b", name: "Second display")
        var displays = DisplayConnectionTracker()
        precondition(displays.update([monitor]).isEmpty, "Existing displays are quiet at startup")
        precondition(displays.update([monitor, monitor]).isEmpty, "Duplicate display entries cannot duplicate cards")
        precondition(displays.update(nil).isEmpty, "A failed screen read is not a disconnection")
        precondition(displays.update([monitor]).isEmpty)
        let connected = displays.update([second, monitor])
        precondition(connected.count == 1 && connected[0].title == "Display connected" && connected[0].detail == second.name)
        let disconnected = displays.update([second])
        precondition(disconnected.count == 1 && disconnected[0].title == "Display disconnected" && disconnected[0].detail == monitor.name,
                     "A removed monitor retains its cached name")
        precondition(displays.update([.init(id: second.id, name: "Renamed display")]).isEmpty,
                     "Resolution, ordering or name updates must not look like new connections")
        precondition(displays.update([monitor, second]).count == 1, "Reconnecting is a new event")

        var queue = SystemNotchEventQueue()
        let start = Date(timeIntervalSince1970: 100)
        queue.enqueue(.amphetamine(true), at: start)
        queue.enqueue(.warp(true), at: start)
        queue.enqueue(connected[0], at: start)
        queue.enqueue(.amphetamine(false), at: start.addingTimeInterval(1))
        precondition(queue.next(at: start.addingTimeInterval(2)) == .warp(true),
                     "A newer state replaces its pending card while retaining the other events")
        queue.remove(.warp(true))
        precondition(queue.next(at: start.addingTimeInterval(2)) == connected[0])
        queue.remove(kind: .display)
        precondition(queue.next(at: start.addingTimeInterval(2)) == .amphetamine(false))
        precondition(queue.next(at: start.addingTimeInterval(31)) == nil,
                     "Events expire if a lock or missing notch keeps them hidden")
        for event in [SystemNotchEvent.amphetamine(true), .amphetamine(false), .warp(true), .warp(false), connected[0], disconnected[0]] {
            precondition(NSImage(systemSymbolName: event.symbol, accessibilityDescription: nil) != nil)
        }
        var presented: [SystemNotchEvent] = []
        let notice = SystemEventNotchNotice(presentEvent: { presented.append($0); return true })
        notice.enqueue(.amphetamine(true))
        notice.enqueue(.warp(true))
        notice.enqueue(connected[0])
        precondition(presented == [.amphetamine(true)],
                     "Simultaneous events must take turns even when a wing accepts immediately")
        RunLoop.main.run(until: Date().addingTimeInterval(SystemNotchEvent.hold + 0.15))
        precondition(presented == [.amphetamine(true), .warp(true)])
        RunLoop.main.run(until: Date().addingTimeInterval(SystemNotchEvent.hold + 0.15))
        precondition(presented == [.amphetamine(true), .warp(true), connected[0]],
                     "Every simultaneous event gets its full turn")
        var allowed = false
        var deferred: [SystemNotchEvent] = []
        let locked = SystemEventNotchNotice(presentEvent: {
            guard allowed else { return false }
            deferred.append($0)
            return true
        })
        locked.enqueue(.amphetamine(true))
        locked.enqueue(.amphetamine(false))
        allowed = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.15))
        precondition(deferred == [.amphetamine(false)], "A suppressed card presents only the latest app state")
        if let native = SystemEventNotchNotice.readDisplays() {
            print("Native display snapshot: \(native.count) external displays (read only)")
        }
        print("Startup suppression, unknown-read handling, app transitions, display identity, event coalescing and expiration checks passed")
    }
}
