"""Replay display changes through the strip's production rebuild decision."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/EdgeKeyStrip.swift").read_text()
key_hud = (root / "MSG/KeyEdgeHUD.swift").read_text()
function_row = "enum FunctionRow {" + key_hud.split("enum FunctionRow {", 1)[1].split(
    "// MARK: - Key HUD", 1
)[0]
signature = source.split("    /// The geometry the caps were laid out with;", 1)[1].split(
    "    private func build(frame:", 1
)[0]
signature = "    /// The geometry the caps were laid out with;" + signature
geometry = "        let rounded = true" + source.split("        let rounded = true", 1)[1].split(
    "        let firstRow = effectiveFirstRow()", 1
)[0]
assignment = next(line.strip() for line in source.splitlines() if "view.layoutSignature =" in line)
restore_row = next(line.strip() for line in source.splitlines() if "if layerShown { view.showSecondRow" in line)
cap_frame = "    private func capFrame(_ key: Int) -> CGRect {" + source.split(
    "    private func capFrame(_ key: Int) -> CGRect {", 1
)[1].split("    /// How far the strip's fill", 1)[0]

harness = r'''
import AppKit
enum CornerCurve { case g2 }
enum CornerGeometry {
    static func reach(for radius: CGFloat, curve: CornerCurve) -> CGFloat { radius }
}
enum EdgeKeysKeyPlacement: CaseIterable { case floating, touching, rising }
final class AppSettings {
    static let shared = AppSettings()
    var cornerRadius: CGFloat = 16
    var cornerCurve = CornerCurve.g2
    var edgeKeysKeyPlacement = EdgeKeysKeyPlacement.touching
    var edgeKeysShowEsc = false
    var edgeKeysShowTouchID = false
    var edgeKeysLayerModifier = "rightShift"
    func extCornerRadius(for uuid: String) -> CGFloat { cornerRadius }
    func extCornerCurve(for uuid: String) -> CornerCurve { cornerCurve }
}
struct Screen {
    var frame: CGRect
    var backingScaleFactor: CGFloat
    let uuid: String? = "builtin"
    let isBuiltin = true
}
''' + function_row + r'''
final class StripView: NSView {
    var layoutSignature: [CGFloat] = []
    var stripHeight: CGFloat
    var capFrames: [CGRect] = []
    var secondRowShown = false
    init(frame: CGRect, height: CGFloat) {
        stripHeight = height
        super.init(frame: frame)
        capFrames = (0...13).map { capFrame($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateFillets(stripHeight: CGFloat, radius: CGFloat, curve: CornerCurve, roundedCorners: Bool) {
        self.stripHeight = stripHeight
    }
    func showSecondRow(_ shown: Bool, modifier: String) { secondRowShown = shown }
''' + cap_frame + r'''
}
final class StripWindow {
    var frame: CGRect
    let view: StripView
    init(frame: CGRect, view: StripView) { self.frame = frame; self.view = view }
    func setFrame(_ frame: CGRect, display: Bool) {
        self.frame = frame
        view.setFrameSize(frame.size)
    }
}
final class StripHarness {
    var window: StripWindow?
    var view: StripView?
    var builds = 0
    var layerShown = false
    var height: CGFloat = 37
''' + signature + r'''
    private func discard() { window = nil; view = nil }
    private func build(frame: CGRect, stripHeight: CGFloat, radius: CGFloat, curve: CornerCurve,
                       roundedCorners: Bool, scale: CGFloat) {
        let view = StripView(frame: CGRect(origin: .zero, size: frame.size), height: stripHeight)
        ''' + assignment + r'''
        ''' + restore_row + r'''
        self.view = view
        window = StripWindow(frame: frame, view: view)
        builds += 1
    }
    func update(screen: Screen, rebuild: Bool = false) {
        let settings = AppSettings.shared
        let baseHeight = height
        let reserve = baseHeight + 6
''' + geometry + r'''
    }
}

let h = StripHarness()
var screen = Screen(frame: CGRect(x: 0, y: 0, width: 2752, height: 1152), backingScaleFactor: 2)
h.layerShown = true
h.update(screen: screen)
precondition(h.builds == 1 && h.view!.secondRowShown)
let original = h.view!
screen.frame.origin = CGPoint(x: -618, y: 982)
h.update(screen: screen)
precondition(h.view === original && h.builds == 1,
             "Moving the display or changing an external display must retain the strip")
precondition(h.window!.frame.origin == screen.frame.origin)

screen.frame.size = CGSize(width: 1512, height: 982)
h.update(screen: screen)
let caps = h.view!.capFrames
precondition(caps.allSatisfy { $0.minX >= 0 && $0.maxX <= screen.frame.width },
             "Shrinking the display must reposition all fourteen keys inside its width")
precondition(abs(caps[1].midX - FunctionRow.center(of: 1) * 1512) < 1,
             "F1 must use the new display width, not its old position")
precondition(h.view !== original && h.builds == 2 && h.view!.secondRowShown,
             "A geometry rebuild must retain the held second row")

let resized = h.view!
h.height = 24
h.update(screen: screen)
precondition(h.view !== resized && h.view!.capFrames[1].height == 18,
             "Changing strip height must resize the caps too")
let shortened = h.view!
screen.backingScaleFactor = 1
h.update(screen: screen)
precondition(h.view !== shortened, "A scale change must recreate the glyph and widget layers")
let rescaled = h.view!
AppSettings.shared.cornerRadius = 24
h.update(screen: screen)
precondition(h.view === rescaled, "Changing corner fillets alone must not rebuild the keys")
h.update(screen: screen)
precondition(h.view === rescaled, "Unchanged geometry must not rebuild on ordinary updates")
h.update(screen: screen, rebuild: true)
precondition(h.view !== rescaled, "An explicitly requested rebuild must still work")
print("Edge Keys display resize, strip height, scale and second-row retention: PASS")
'''

with tempfile.TemporaryDirectory(prefix="msg-edge-geometry-") as directory:
    swift = Path(directory) / "main.swift"
    binary = Path(directory) / "tests"
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(binary), "-framework", "AppKit"],
                   env=env, check=True)
    subprocess.run([str(binary)], check=True)
