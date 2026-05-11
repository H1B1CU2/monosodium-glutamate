import AppKit
import Foundation

/// File-backed diagnostic logger. Writes structured events to /tmp/msg_diag.log
/// so we can observe CGS behavior around MC/fullscreen transitions.
final class Diagnostics {

    static let shared = Diagnostics()

    private let path = "/tmp/msg_diag.log"
    private var handle: FileHandle?
    private var seq = 0
    private let startTime = ProcessInfo.processInfo.systemUptime
    private let queue = DispatchQueue(label: "diag", qos: .utility)

    init() {
        // Truncate
        try? Data().write(to: URL(fileURLWithPath: path))
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    deinit { handle?.closeFile() }

    func event(_ msg: String) {
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            self.seq += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - self.startTime
            let line = String(format: "[%07.3f] #%04d %@\n", elapsed, self.seq, msg)
            if let data = line.data(using: .utf8) { h.write(data) }
        }
    }

    /// Dump raw CGS display dicts in detail
    func dumpCGS(_ displayDicts: [[String: Any]], activeID: Int) {
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            self.seq += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - self.startTime
            var lines: [String] = []
            lines.append(String(format: "[%07.3f] #%04d ═══ CGS DUMP ═══", elapsed, self.seq))
            lines.append(String(format: "   activeID=%d  displays=%d", activeID, displayDicts.count))

            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            let fs = !NSMenu.menuBarVisible()
            lines.append("   frontmost=\(bundle)  menuBarHidden=\(fs)")

            for (di, dict) in displayDicts.enumerated() {
                let ident = dict["Display Identifier"] as? String ?? "?"
                let spaces = dict["Spaces"] as? [[String: Any]] ?? []
                let cs = dict["Current Space"] as? [String: Any]
                let csMsid = cs?["ManagedSpaceID"] as? Int ?? -1
                let csID64 = cs?["id64"] as? Int ?? -1

                lines.append("   Display[\(di)] id=\(ident)")
                lines.append(String(format: "     CurrentSpace: ManagedSpaceID=%d  id64=%d", csMsid, csID64))

                for (si, s) in spaces.enumerated() {
                    let msid = s["ManagedSpaceID"] as? Int ?? -1
                    let i64 = s["id64"] as? Int ?? -1
                    let tile = s["TileLayoutManager"] is [String: Any] ? " FS" : ""
                    let pid = s["pid"] as? pid_t
                    let proc = pid.map { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "?" } ?? "-"
                    let marker = (msid == csMsid) ? " ←CURRENT" : ""
                    lines.append(String(format: "     [%d] ManagedSpaceID=%d  id64=%d  pid=%d(%@)%@%@", si, msid, i64, pid ?? -1, proc, tile, marker))
                }
            }

            lines.append("   ─── computed ───")
            // Peek at computed values by calling readSpaceInfo inline (approximate — we can't
            // call the static method here without duplicating logic, so we show raw only)
            lines.append("   ═══ END CGS ═══\n")

            let out = lines.joined(separator: "\n") + "\n"
            if let data = out.data(using: .utf8) { h.write(data) }
        }
    }

    /// Log a SpaceInfo change
    func spaceInfoChange(old: SpaceInfo, new: SpaceInfo) {
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            self.seq += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - self.startTime
            var lines: [String] = []
            lines.append(String(format: "[%07.3f] #%04d ★ SPACE INFO CHANGED", elapsed, self.seq))
            for (i, d) in new.displays.enumerated() {
                let oldCur = i < old.displays.count ? old.displays[i].current : -1
                let arrow = oldCur != d.current ? " ←CHANGED(from \(oldCur))" : ""
                let tag = i == new.activeDisplayIndex ? "★" : " "
                lines.append("   \(tag)[\(i)] cur=\(d.current) total=\(d.total)\(arrow)")
            }
            let oldAct = old.activeDisplayIndex
            if oldAct != new.activeDisplayIndex {
                lines.append("   activeDisplayIdx: \(oldAct) → \(new.activeDisplayIndex) ←CHANGED")
            }
            lines.append("")
            let out = lines.joined(separator: "\n") + "\n"
            if let data = out.data(using: .utf8) { h.write(data) }
        }
    }

    func notificationFired(debounced: Bool) {
        event("🔔 activeSpaceDidChange (debounced spawn: \(debounced))")
    }

    func indicatorRefreshed(info: SpaceInfo) {
        event("🖥 indicator refresh — activeIdx=\(info.activeDisplayIndex)  spaces=\(info.displays.map { $0.current })")
    }

    func stateChange(stable: Bool, fullscreen: Bool, mc: Bool) {
        event("📊 state: stable=\(stable)  fullscreen=\(fullscreen)  missionControl=\(mc)")
    }

    func flush() {
        queue.sync { handle?.synchronizeFile() }
    }
}
