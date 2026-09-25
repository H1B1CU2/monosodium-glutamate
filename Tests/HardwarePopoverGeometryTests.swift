import AppKit

@main struct HardwarePopoverGeometryTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var stats = HardwareStats()
        stats.batteryPercent = 90
        stats.adapterWatts = 57
        stats.powerWatts = 24.6
        stats.chargeLimitPercent = 90
        stats.cpuTemp = 58
        stats.memoryUsedGB = 18.4
        stats.fans = [FanInfo(index: 0, name: "Left", current: 2300, min: 0, max: 8000)]
        let samples = [18.0, 22, 28, 24, 32, 48.7, 24.6]

        func render(_ view: HardwarePopoverContentView, side: String, hidden: Set<String> = ["fps"]) -> [String: NSRect] {
            view.cardColumns = [["temp", "memory"], ["gpu"], ["cpu", "fps"]]
            view.moduleOrder = ["battery", "temp", "memory", "gpu", "cpu", "fps", "fan"]
            view.batteryCardSpan = "2x2"
            view.batteryCardSide = side
            view.hiddenCards = hidden
            view.energyModes = HardwareMonitor.EnergyModes(battery: 0, ac: 0)
            view.rebuild(stats: stats, powerSamples: samples)
            view.setFrameSize(NSSize(width: view.popWidth, height: view.contentHeight))
            view.layoutSubtreeIfNeeded()
            return view.cardFrames
        }
        for side in ["left", "right"] {
            let live = HardwarePopoverContentView()
            let preview = HardwarePopoverContentView(isInteractive: true, arrowHeight: 8, blendingMode: .withinWindow)
            let a = render(live, side: side), b = render(preview, side: side)
            precondition(Set(a.keys) == ["battery", "temp", "memory", "gpu", "cpu", "fan"])
            for id in a.keys {
                let first = a[id]!, second = b[id]!
                precondition(abs(first.minX - second.minX) < 0.5 && abs(first.minY - second.minY) < 0.5)
                precondition(abs(first.width - second.width) < 0.5 && abs(first.height - second.height) < 0.5)
            }
            let battery = a["battery"]!, temp = a["temp"]!, memory = a["memory"]!
            precondition(abs(battery.maxY - temp.maxY) < 0.5, "TEMP must meet Battery's top")
            precondition(abs(battery.minY - memory.minY) < 0.5, "MEM must meet Battery's bottom")
            precondition(abs(temp.height - memory.height) < 0.5, "Side cards must share extra height equally")
            precondition(temp.height > 66, "Side cards must stretch beyond their compact height")
            precondition(abs(a["gpu"]!.height - 66) < 0.5 && abs(a["cpu"]!.height - 66) < 0.5)
            precondition(abs(a["gpu"]!.width + 8 + a["cpu"]!.width - live.contentWidth) < 0.5)
            precondition(side == "left" ? battery.maxX < temp.minX : battery.minX > temp.maxX)
            print("PASS: \(side) Battery — preview/live geometry matches, side cards \(temp.height) pt fill \(battery.height) pt")
        }
        let batteryOnly = HardwarePopoverContentView()
        let lone = render(batteryOnly, side: "left", hidden: Set(HardwareCardLayout.statistics + ["fan"]))
        precondition(abs(lone["battery"]!.width - batteryOnly.contentWidth) < 0.5)
        print("PASS: Battery fills the row when no side cards are visible")
        let allHidden = HardwarePopoverContentView()
        let empty = render(allHidden, side: "left", hidden: Set(HardwareCardLayout.modules))
        precondition(empty.isEmpty)
        print("PASS: hidden cards are absent from drag geometry")
    }
}
