import Foundation
import CoreGraphics

func check(_ layout: HardwareCardLayout) {
    let ids = layout.columns.flatMap { $0 }
    precondition(Set(ids) == Set(HardwareCardLayout.statistics))
    precondition(ids.count == Set(ids).count)
    precondition((1...3).contains(layout.columns.count))
    precondition(layout.columns.allSatisfy { !$0.isEmpty })
    precondition(Set(layout.order) == Set(HardwareCardLayout.modules))
    precondition(layout.order.count == HardwareCardLayout.modules.count)
}

@main struct LayoutTests {
    static func main() {
        var layout = HardwareCardLayout(columns: [["temp", "memory"], ["gpu"], ["cpu", "fps"]],
                                        order: ["battery", "temp", "memory", "gpu", "cpu", "fps", "fan"],
                                        batterySpan: "2x2", batterySide: "left")
        check(layout)
        precondition(layout.move("cpu", target: "temp", edge: .before, composite: true))
        precondition(Array(layout.columns.flatMap { $0 }.prefix(2)) == ["cpu", "temp"])
        let before = layout
        precondition(!layout.move("cpu", target: "temp", edge: .left, composite: true))
        precondition(layout == before)
        precondition(layout.move("battery", target: "memory", edge: .right, composite: true))
        precondition(layout.batterySide == "right")
        precondition(layout.columns.flatMap { $0 }.first == "memory")
        precondition(layout.move("battery", target: "cpu", edge: .after, composite: true))
        precondition(layout.batterySpan == "full")
        precondition(layout.order.firstIndex(of: "battery")! > layout.order.firstIndex(of: "cpu")!)
        layout.setColumnCount(2)
        let order = layout.columns.flatMap { $0 }
        layout.setColumnCount(3)
        precondition(layout.columns.flatMap { $0 } == order)
        check(layout)

        var stale = HardwareCardLayout(columns: [["cpu", "cpu", "wrong"], [], ["memory", "memory"]],
                                       order: ["cpu", "cpu", "invalid"], batterySpan: "garbage", batterySide: "garbage")
        check(stale)
        let untouched = stale
        precondition(!stale.move("wrong", target: "cpu", edge: .before, composite: false))
        precondition(stale == untouched)
        stale.setModuleOrder(Array(HardwareCardLayout.modules.reversed()))
        precondition(stale.columns.flatMap { $0 } == stale.order.filter { HardwareCardLayout.statistics.contains($0) })

        // Exhaust every source/target/edge pair, including blocked and no-op
        // drops, over all column counts and both battery arrangements.
        for count in 1...3 {
            for composite in [false, true] {
                for source in HardwareCardLayout.modules {
                    for target in HardwareCardLayout.modules {
                        for edge in HardwareCardLayout.Edge.allCases {
                            var candidate = layout
                            candidate.setColumnCount(count)
                            _ = candidate.move(source, target: target, edge: edge, composite: composite)
                            check(candidate)
                        }
                    }
                }
            }
        }
        let hitLayout = HardwareCardLayout(columns: [["temp", "memory"], ["gpu"], ["cpu", "fps"]],
                                           order: HardwareCardLayout.modules, batterySpan: "2x2", batterySide: "left")
        let frames = ["battery": CGRect(x: 0, y: 100, width: 230, height: 180),
                      "temp": CGRect(x: 238, y: 194, width: 110, height: 86),
                      "memory": CGRect(x: 238, y: 100, width: 110, height: 86),
                      "gpu": CGRect(x: 0, y: 26, width: 170, height: 66),
                      "cpu": CGRect(x: 178, y: 26, width: 170, height: 66)]
        let top = HardwareCardDrop.resolve(dragged: "cpu", point: CGPoint(x: 240, y: 278),
                                          frames: frames, arrangement: hitLayout, composite: true)
        precondition(top?.target == "temp" && top?.edge == .before)
        let side = HardwareCardDrop.resolve(dragged: "cpu", point: CGPoint(x: 228, y: 210),
                                           frames: frames, arrangement: hitLayout, composite: true)
        precondition(side?.target == "battery" && side?.edge == .right)
        precondition(HardwareCardDrop.resolve(dragged: "cpu", point: CGPoint(x: 200, y: 50),
                                              frames: frames, arrangement: hitLayout, composite: true) == nil)
        // Resolving a hover repeatedly must not mutate either model or frames.
        for _ in 0..<100 {
            let repeated = HardwareCardDrop.resolve(dragged: "cpu", point: CGPoint(x: 240, y: 278),
                                                    frames: frames, arrangement: hitLayout, composite: true)
            precondition(repeated?.indicator == top?.indicator)
        }
        print("PASS: 1,176 reorder cases; normalization, duplicate prevention, column limits, linked order, and Battery placement")
    }
}
