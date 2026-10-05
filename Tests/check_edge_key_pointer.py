"""Exercise the strip's actual pointer-monitor lifecycle without moving the user's mouse."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/EdgeKeyStrip.swift").read_text()
monitor = source.split("    private var pointerApp:", 1)[1].split(
    "    /// The frontmost ordinary window under the pointer", 1
)[0]
monitor = "    private var pointerApp:" + monitor

harness = '''
import AppKit
import QuartzCore
final class AppSettings {
    static let shared = AppSettings()
    var edgeKeysAppKeys = true
    var edgeKeysAppKeysFollowPointer = true
}
enum EdgeKeys {
    enum Mode { case strip, off }
    static var mode = Mode.strip
}
final class PointerHarness {
    var isVisible = true
    var appRowFor: String?
    var updates = 0
    static var target: (NSRunningApplication, CGWindowID)?
    private static func appUnderPointer() -> (NSRunningApplication, CGWindowID)? { target }
    private func update() { updates += 1 }
    private func writePointerDiagnostics() {}
''' + monitor + '''
    static func run() {
        let h = PointerHarness()
        let first = NSRunningApplication.current
        let second = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
        target = (first, 1)
        h.updatePointerMonitor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(h.pointerApp?.processIdentifier == first.processIdentifier && h.updates == 1,
                     "Startup resolves the current pointer without an event")
        let count = h.pointerMonitors.count
        h.updatePointerMonitor()
        precondition(h.pointerMonitors.count == count, "Updates don't duplicate event monitors")

        // No mouse event: another window now occupies the same pointer position.
        target = (second, 2)
        h.lastPointerCheck = 0
        h.pointerPoll!.fire()
        precondition(h.pointerApp?.processIdentifier == second.processIdentifier && h.updates == 2,
                     "The fallback timer changes app keys without global mouse events")
        target = (second, 3)
        h.lastPointerCheck = 0
        h.pointerPoll!.fire()
        precondition(h.pointerWindow == 3 && h.updates == 2,
                     "Changing windows in one app updates the shortcut destination without reshuffling")
        target = nil
        h.lastPointerCheck = 0
        h.pointerPoll!.fire()
        precondition(h.pointerWindow == 3, "Desktop/menu/strip keeps the last chosen app")

        // Queue a throttled check, then disable tracking before it executes.
        h.pointerMoved()
        AppSettings.shared.edgeKeysAppKeysFollowPointer = false
        h.updatePointerMonitor()
        target = (first, 4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        precondition(h.pointerPoll == nil && h.pointerMonitors.isEmpty && h.pointerCheckWork == nil)
        precondition(h.pointerApp == nil && h.pointerWindow == 0 && h.updates == 2,
                     "Disabled tracking cannot restore a stale pointer target")
        AppSettings.shared.edgeKeysAppKeysFollowPointer = true
        h.updatePointerMonitor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(h.pointerApp?.processIdentifier == first.processIdentifier && h.updates == 3)
        EdgeKeys.mode = .off
        h.updatePointerMonitor()
        precondition(h.pointerPoll == nil && h.pointerMonitors.isEmpty)
        print("Edge Keys pointer startup, missing-event recovery and lifecycle: PASS")
    }
}
PointerHarness.run()
'''
with tempfile.TemporaryDirectory(prefix="msg-pointer-tests-") as directory:
    swift = Path(directory) / "main.swift"
    binary = Path(directory) / "tests"
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary), "-framework", "AppKit"],
                   env=env, check=True)
    subprocess.run([str(binary)], check=True)
