"""Replay the WindowServer hierarchy that kept the pointer target stuck on SP8CE."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/EdgeKeyStrip.swift").read_text()
selector = source.split("// MARK: - Pointer hit testing", 1)[1].split("// MARK: - Strip", 1)[0]
harness = '''
import AppKit
''' + selector + '''
let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
let external = CGRect(x: -618, y: -1152, width: 2752, height: 1152)
let displays = [primary, external]
func window(_ id: UInt32, _ pid: Int32, _ bundle: String, _ layer: Int, _ bounds: CGRect,
            regular: Bool = true, alpha: Double = 1) -> EdgeKeyPointerWindow {
    .init(id: id, pid: pid, bundle: bundle, regular: regular, layer: layer, bounds: bounds, alpha: alpha)
}
let msg = window(2561, 41924, "H1D3S1GN.MSG", 1500, primary, regular: false)
let dock = window(40, 703, "com.apple.dock", 20, primary, regular: false)
let claude = window(607, 3969, "com.anthropic.claudefordesktop", 0,
                    CGRect(x: 0, y: 33, width: 721, height: 910))
let codex = window(642, 3964, "com.openai.codex", 0,
                   CGRect(x: 721, y: 33, width: 727, height: 910))
let sp8ce = window(320, 1726, "com.kite.Kite", 0,
                   CGRect(x: -618, y: -1122, width: 2752, height: 1122))
let hierarchy = [msg, dock, sp8ce, codex, claude]
func target(_ windows: [EdgeKeyPointerWindow], _ point: CGPoint, dockHit: Bool = false) -> String? {
    EdgeKeyPointerWindow.target(in: windows, at: point, ignoring: 41924,
                                displayBounds: displays, pointerOnDock: dockHit)?.bundle
}
precondition(target(hierarchy, CGPoint(x: 300, y: 482)) == claude.bundle,
             "The full-display Dock surface must not hide Claude from pointer selection")
precondition(target(hierarchy, CGPoint(x: 1000, y: 482)) == codex.bundle)
precondition(target(hierarchy, CGPoint(x: 300, y: -518)) == sp8ce.bundle,
             "Negative coordinates on an external display select SP8CE")
precondition(target(hierarchy, CGPoint(x: 300, y: 482), dockHit: true) == nil,
             "An actual Dock hit still holds the previous row")
let tray = window(41, 703, "com.apple.dock", 20,
                  CGRect(x: 100, y: 850, width: 1000, height: 100), regular: false)
precondition(target([tray, claude], CGPoint(x: 300, y: 900)) == nil,
             "A bounded Dock panel is still an interactive obstruction")
let menu = window(42, 3964, "com.openai.codex", 24,
                  CGRect(x: 250, y: 400, width: 200, height: 200))
precondition(target([menu, dock, claude], CGPoint(x: 300, y: 482)) == nil,
             "An app's menu must not select the window underneath it")
let transparent = window(43, 3964, "com.openai.codex", 24, primary, alpha: 0)
precondition(target([transparent, dock, claude], CGPoint(x: 300, y: 482)) == claude.bundle)
precondition(target(hierarchy, CGPoint(x: 2000, y: 500)) == nil)
print("Edge Keys real Dock hierarchy, app selection and menu/Dock exclusions: PASS")
'''
with tempfile.TemporaryDirectory(prefix="msg-pointer-window-tests-") as directory:
    swift = Path(directory) / "main.swift"
    binary = Path(directory) / "tests"
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary), "-framework", "AppKit"],
                   env=env, check=True)
    subprocess.run([str(binary)], check=True)
