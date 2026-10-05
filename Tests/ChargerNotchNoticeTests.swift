import AppKit

// Isolate the power listener from real windows and settings. The listener tests
// inject power snapshots; native IOPS access is read-only and no power is changed.
final class AppSettings {
    static let shared = AppSettings()
    var notchChargerNotice = true
}
final class PresentationState {
    static let shared = PresentationState()
    func addObserver(_ observer: @escaping () -> Void) {}
}
final class NotchHUD {
    static let shared = NotchHUD()
    private(set) var presentations = 0
    private(set) var state: ChargerPowerState?
    var canPresent = true
    func showCharger(_ state: ChargerPowerState) -> Bool {
        guard canPresent else { return false }
        presentations += 1
        self.state = state
        return true
    }
    func updateCharger(_ state: ChargerPowerState) {
        guard self.state != nil else { return }
        self.state = state
    }
    func dismissCharger() { state = nil }
}

@main
struct ChargerNotchNoticeTests {
    static func main() {
        func power(_ connected: Bool, watts: Int? = 60, percent: Int = 86,
                   charging: Bool = true) -> ChargerPowerState {
            ChargerPowerState.parse(source: ["Power Source State": connected ? "AC Power" : "Battery Power",
                                             "Current Capacity": percent, "Max Capacity": 100,
                                             "Is Charging": charging],
                                    adapter: watts.map { ["Watts": $0] })!
        }

        var tracker = ChargerConnectionTracker()
        precondition(!tracker.update(power(true)), "An already-connected adapter must be silent at launch")
        precondition(!tracker.update(power(true, percent: 87)), "Battery changes are not cable attachments")
        precondition(!tracker.update(power(true, percent: 87, charging: false)), "Charging pauses are still connected")
        precondition(!tracker.update(power(true, watts: 100)), "PD wattage changes must not create another card")
        let unplugged = power(false)
        precondition(!unplugged.connected && unplugged.adapterWatts == nil,
                     "Ignore stale adapter data after unplugging")
        precondition(unplugged.titleText == "Power disconnected" && unplugged.valueText == "86%"
                     && unplugged.detailText == "Running on battery" && unplugged.wingText == "Unplugged · 86%",
                     "Unplug has its own battery card and wing text, without stale charging or wattage labels")
        precondition(NSImage(systemSymbolName: unplugged.symbolName, accessibilityDescription: nil) != nil,
                     "The disconnected battery symbol must exist on this Mac")
        precondition(!tracker.update(unplugged))
        let negotiating = power(true, watts: nil)
        precondition(tracker.update(negotiating), "A battery-to-AC transition must create one attachment")
        precondition(negotiating.adapterWatts == nil && negotiating.valueText == "–",
                     "A new adapter must not reuse the previous adapter's watts")
        precondition(negotiating.detailText == "Adapter wattage unavailable")
        precondition(!tracker.update(power(true)), "Negotiation updates must not duplicate the card")
        precondition(!tracker.update(power(false)))
        precondition(tracker.update(power(true, watts: 30)), "The next cable attachment must be detected")
        precondition(power(true, watts: 0).adapterWatts == nil && power(true, watts: -1).adapterWatts == nil)
        precondition(power(true).valueText == "60 W")
        precondition(power(true).detailText == "86% battery · Charging")
        precondition(power(true, charging: false).detailText == "86% battery · Charging paused")
        precondition(power(true, percent: 100, charging: false).detailText == "100% battery · Fully charged")

        // Reproduce AC/watts arriving first, followed by charging without a
        // second cable attachment. Time is injected; no physical cable needed.
        let start = Date(timeIntervalSince1970: 100)
        var settling = ChargerConnectionTracker()
        precondition(!settling.update(power(false), at: start))
        precondition(settling.update(power(true, charging: false), at: start))
        precondition(settling.latest?.charging == false, "Keep the real power reading intact")
        precondition(settling.noticeState(at: start)?.detailText == "86% battery",
                     "The initial not-charging snapshot must not claim a pause")
        let early = start.addingTimeInterval(0.25)
        precondition(settling.isSettling(at: early),
                     "Ready adapter watts must not end charging-state retries")
        precondition(settling.noticeState(at: early)?.charging == nil)
        precondition(!settling.update(power(true, percent: 87), at: start.addingTimeInterval(1)))
        precondition(settling.noticeState(at: start.addingTimeInterval(1))?.detailText == "87% battery · Charging",
                     "A confirmed charging reading updates the same attachment immediately")
        precondition(!settling.update(power(true, charging: false), at: start.addingTimeInterval(2)))
        precondition(settling.noticeState(at: start.addingTimeInterval(2))?.charging == nil,
                     "A negotiation fluctuation must stay neutral during settling")
        let settled = start.addingTimeInterval(ChargerConnectionTracker.settlingDuration)
        precondition(!settling.isSettling(at: settled), "Retries have a fixed deadline")
        precondition(settling.noticeState(at: settled)?.detailText == "86% battery · Charging paused",
                     "A genuinely persistent non-charging state is still shown after settling")
        precondition(!settling.update(power(false), at: settled))
        precondition(!settling.isSettling(at: settled) && settling.noticeState(at: settled)?.connected == false,
                     "Unplugging cancels settlement and never keeps an AC presentation")
        precondition(settling.update(power(true, watts: 30, charging: false), at: settled))
        precondition(settling.noticeState(at: settled)?.charging == nil,
                     "Replugging starts a fresh charging-state grace period")
        precondition(!settling.update(power(true, watts: 30, percent: 100, charging: false), at: settled))
        precondition(settling.noticeState(at: settled)?.detailText == "100% battery · Fully charged",
                     "An already-full battery keeps its useful status during settling")
        var alreadyConnected = ChargerConnectionTracker()
        precondition(!alreadyConnected.update(power(true, charging: false), at: start))
        precondition(!alreadyConnected.isSettling(at: start) && alreadyConnected.noticeState(at: start)?.charging == false,
                     "Startup must not start attachment retries or mask a real charging pause")
        precondition(ChargerPowerState.parse(source: [:], adapter: ["Watts": 60]) == nil,
                     "An unavailable power state must not be guessed")
        let scaled = ChargerPowerState.parse(source: ["Power Source State": "AC Power",
                                                       "Current Capacity": 43, "Max Capacity": 50],
                                              adapter: ["Watts": 60])!
        precondition(scaled.batteryPercent == 86, "Convert capacity to a percentage")
        precondition(power(true, percent: 120).batteryPercent == 100)
        precondition(power(true, percent: -10).batteryPercent == 0)
        let invalidCapacity = ChargerPowerState.parse(source: ["Power Source State": "AC Power",
                                                                "Current Capacity": 43, "Max Capacity": 0],
                                                        adapter: ["Watts": 60])!
        precondition(invalidCapacity.batteryPercent == nil)

        // Exercise the actual listener and dispatch retries against a fake
        // battery, with no real notch window or hardware write.
        var input = power(false)
        var reads = 0
        let notice = ChargerNotchNotice(readPowerState: {
            reads += 1
            return input
        })
        notice.settingChanged()
        let hud = NotchHUD.shared
        precondition(hud.presentations == 0, "The listener seeds quietly")
        input = power(true, charging: false)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(hud.presentations == 1 && hud.state?.charging == nil,
                     "Ready watts show one neutral attachment card while charging settles")
        input = power(true)
        // Deliberately do not deliver another power notification. The short
        // retry must update the card after showing it cleared the pending notice.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(hud.presentations == 1 && hud.state?.charging == true,
                     "Late charging updates reach the visible card without another notification")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        let settledReadCount = reads
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(reads == settledReadCount, "Settlement must stop reading once its deadline passes")
        input = power(false)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(hud.presentations == 2 && hud.state?.connected == false && hud.state?.valueText == "86%",
                     "Unplugging replaces the charging card with one battery card")
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(hud.presentations == 2, "Battery updates must not repeat the unplug card")
        input = power(true, watts: 30, charging: false)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(hud.presentations == 3 && hud.state?.adapterWatts == 30 && hud.state?.charging == nil,
                     "A second adapter gets its own neutral card and fresh wattage")
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        precondition(hud.presentations == 3 && hud.state?.charging == false,
                     "A lasting charging pause is confirmed on the existing card after settling")
        input = power(false)
        notice.powerChanged()
        input = power(true, charging: false)
        notice.powerChanged()
        input = power(false)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(hud.presentations == 4 && hud.state?.connected == false,
                     "Rapid unplug/replug ends with one card for the final state, without a stale attachment")

        // If another surface owns the notch, retain only the latest transition.
        hud.canPresent = false
        input = power(true)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        input = power(false, percent: 85)
        notice.powerChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(hud.presentations == 4, "Suppressed power cards wait their turn")
        hud.canPresent = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        precondition(hud.presentations == 5 && hud.state?.connected == false && hud.state?.batteryPercent == 85,
                     "A deferred unplug card replaces an older pending attachment")
        input = power(true, charging: false)
        notice.powerChanged()
        AppSettings.shared.notchChargerNotice = false
        notice.settingChanged()
        let disabledReadCount = reads
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        precondition(hud.presentations == 5 && hud.state == nil && reads == disabledReadCount,
                     "Disabling the notice cancels every pending read and card")

        if let native = ChargerPowerState.read() {
            precondition(native.batteryPercent.map { (0...100).contains($0) } ?? true)
            precondition(native.connected || native.adapterWatts == nil)
            print("Native IOPS read: connected=\(native.connected), adapter=\(native.valueText), battery=\(native.batteryPercent.map(String.init) ?? "unavailable")%")
        } else {
            print("Native IOPS read: no internal battery reported")
        }
        print("Power parsing, startup suppression, attachment settling, charging updates, bounded retries, unplug cards and deferred transition checks passed")
    }
}
