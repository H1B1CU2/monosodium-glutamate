import Foundation
import CoreGraphics

/// The persisted card arrangement and all reorder rules, shared by both editors.
/// Moves operate on stable card IDs, never indices into a filtered preview.
struct HardwareCardLayout: Equatable {
    static let modules = ["cpu", "gpu", "memory", "temp", "fan", "battery", "fps"]
    static let statistics = ["cpu", "gpu", "memory", "temp", "fps"]
    enum Edge: CaseIterable { case before, after, left, right }

    var columns: [[String]]
    var order: [String]
    var batterySpan: String
    var batterySide: String

    init(columns: [[String]], order: [String], batterySpan: String, batterySide: String) {
        self.columns = Self.normalize(columns)
        var seen = Set<String>()
        self.order = (order + Self.modules).filter { Self.modules.contains($0) && seen.insert($0).inserted }
        self.batterySpan = batterySpan == "full" ? "full" : "2x2"
        self.batterySide = batterySide == "right" ? "right" : "left"
    }

    static func normalize(_ input: [[String]]) -> [[String]] {
        var seen = Set<String>()
        var result = input.prefix(3).map { column in
            column.filter { statistics.contains($0) && seen.insert($0).inserted }
        }.filter { !$0.isEmpty }
        if result.isEmpty { result = [[]] }
        for id in statistics where !seen.contains(id) {
            let index = result.indices.min { result[$0].count < result[$1].count } ?? 0
            result[index].append(id)
        }
        return result
    }

    /// Updates the linked menu order without moving Battery/Fans unnecessarily.
    private mutating func syncOrder() {
        var iterator = columns.flatMap { $0 }.makeIterator()
        order = order.map { Self.statistics.contains($0) ? (iterator.next() ?? $0) : $0 }
    }

    /// The order-list editor keeps the user's chosen column lengths.
    mutating func setModuleOrder(_ proposed: [String]) {
        var seen = Set<String>()
        order = (proposed + Self.modules).filter { Self.modules.contains($0) && seen.insert($0).inserted }
        distribute(order.filter { Self.statistics.contains($0) })
    }

    private mutating func distribute(_ ids: [String]) {
        var remaining = ids[...]
        columns = columns.map { column in
            let amount = min(column.count, remaining.count)
            let slice = Array(remaining.prefix(amount))
            remaining = remaining.dropFirst(amount)
            return slice
        }.filter { !$0.isEmpty }
        if !remaining.isEmpty {
            if columns.isEmpty { columns = [Array(remaining)] }
            else { columns[columns.count - 1].append(contentsOf: remaining) }
        }
    }

    mutating func setColumnCount(_ count: Int) {
        let ids = columns.flatMap { $0 }
        let count = min(3, max(1, count))
        var next = Array(repeating: [String](), count: count)
        // Preserve the visible reading order as columns are added or removed.
        for (i, id) in ids.enumerated() { next[min(count - 1, i * count / ids.count)].append(id) }
        columns = next.filter { !$0.isEmpty }
        syncOrder()
    }

    private mutating func prioritizeSideCard(_ id: String) {
        var ids = columns.flatMap { $0 }
        ids.removeAll { $0 == id }; ids.insert(id, at: 0)
        distribute(ids)
        if columns.count < 3 { setColumnCount(3) }
        syncOrder()
    }

    /// Repositions an entire visible section. The renderer groups statistics,
    /// so its menu-order slots travel together for an unambiguous result.
    private mutating func moveSection(_ source: [String], beside targets: [String], after: Bool) {
        let moving = order.filter { source.contains($0) }
        order.removeAll { source.contains($0) }
        let indices = order.indices.filter { targets.contains(order[$0]) }
        let insertion = after ? ((indices.last.map { $0 + 1 }) ?? order.count) : (indices.first ?? 0)
        order.insert(contentsOf: moving, at: insertion)
    }

    /// Returns false for a no-op or unsupported move. In particular, a fourth
    /// column is rejected instead of silently dropping into a different column.
    @discardableResult
    mutating func move(_ dragged: String, target: String, edge: Edge, composite: Bool) -> Bool {
        guard dragged != target, Self.modules.contains(dragged), Self.modules.contains(target) else { return false }
        let original = self
        let sourceStat = Self.statistics.contains(dragged)
        let targetStat = Self.statistics.contains(target)
        let horizontal = edge == .left || edge == .right

        if horizontal && (dragged == "battery" && targetStat || target == "battery" && sourceStat) {
            batterySpan = "2x2"
            batterySide = dragged == "battery" ? (edge == .left ? "left" : "right") : (edge == .left ? "right" : "left")
            prioritizeSideCard(sourceStat ? dragged : target)
        } else if sourceStat && targetStat {
            if composite {
                guard !horizontal else { return false }
                var ids = columns.flatMap { $0 }
                ids.removeAll { $0 == dragged }
                guard let index = ids.firstIndex(of: target) else { return false }
                ids.insert(dragged, at: index + (edge == .after ? 1 : 0))
                distribute(ids)
            } else {
                var next = columns.map { $0.filter { $0 != dragged } }.filter { !$0.isEmpty }
                guard let column = next.firstIndex(where: { $0.contains(target) }) else { return false }
                if horizontal {
                    guard next.count < 3 else { return false }
                    next.insert([dragged], at: column + (edge == .right ? 1 : 0))
                } else {
                    let index = next[column].firstIndex(of: target)!
                    next[column].insert(dragged, at: index + (edge == .after ? 1 : 0))
                }
                columns = next
            }
            syncOrder()
        } else {
            guard !horizontal else { return false }
            if dragged == "battery" || target == "battery" { batterySpan = "full" }
            var source = sourceStat ? Self.statistics : [dragged]
            var destination = targetStat ? Self.statistics : [target]
            // Fans cross the whole Battery + statistics section in the wide
            // layout; Battery cannot accidentally move to the other side of it.
            if composite && dragged != "battery" && target != "battery" {
                if sourceStat { source.append("battery") }
                if targetStat { destination.append("battery") }
            }
            moveSection(source, beside: destination, after: edge == .after)
        }
        return self != original
    }
}

/// Drop geometry is resolved without changing the arrangement or view frames.
struct HardwareCardDrop {
    let target: String
    let edge: HardwareCardLayout.Edge
    let indicator: CGRect

    static func resolve(dragged: String, point: CGPoint, frames: [String: CGRect],
                        arrangement: HardwareCardLayout, composite: Bool) -> HardwareCardDrop? {
        guard let own = frames[dragged], !own.insetBy(dx: 4, dy: 4).contains(point) else { return nil }
        let candidates = frames.filter { $0.key != dragged }.sorted { a, b in
            func distance(_ rect: CGRect) -> CGFloat {
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                return dx * dx + dy * dy
            }
            let da = distance(a.value), db = distance(b.value)
            return da == db ? a.key < b.key : da < db
        }
        guard let (target, rect) = candidates.first else { return nil }
        let horizontalInset = min(24, rect.width * 0.18)
        let verticalInset = min(16, rect.height * 0.22)
        let edge: HardwareCardLayout.Edge
        // Corners and inter-row gaps belong to vertical insertion. This avoids
        // accidentally creating a column when aiming above the start of a card.
        if point.y >= rect.maxY - verticalInset { edge = .before }
        else if point.y <= rect.minY + verticalInset { edge = .after }
        else if point.x < rect.minX + horizontalInset { edge = .left }
        else if point.x > rect.maxX - horizontalInset { edge = .right }
        else { edge = point.y >= rect.midY ? .before : .after }
        var proposed = arrangement
        guard proposed.move(dragged, target: target, edge: edge, composite: composite) else { return nil }
        let line: CGRect
        switch edge {
        case .before: line = CGRect(x: rect.minX, y: rect.maxY + 2, width: rect.width, height: 3)
        case .after: line = CGRect(x: rect.minX, y: rect.minY - 5, width: rect.width, height: 3)
        case .left: line = CGRect(x: rect.minX - 5, y: rect.minY, width: 3, height: rect.height)
        case .right: line = CGRect(x: rect.maxX + 2, y: rect.minY, width: 3, height: rect.height)
        }
        return HardwareCardDrop(target: target, edge: edge, indicator: line)
    }
}
