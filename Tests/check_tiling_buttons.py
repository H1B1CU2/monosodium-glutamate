#!/usr/bin/env python3
"""Exercise production button event handling without launching MSG or opening windows."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'MSG/TilingControlBar.swift').read_text()
view = source[source.index('private final class TilingControlBarView: NSView {'):]
renderer = (root / 'MSG/IndicatorRenderer.swift').read_text()
pipeline = renderer[renderer.index('// MARK: - Shared Space-pill pipeline'):renderer.index('/// Pure drawing functions')]
indicator = (root / 'MSG/Indicator.swift').read_text()
easing = indicator[indicator.index('enum Easing {'):indicator.index('// MARK: - RightClickTracker')]
controller = (root / 'MSG/TilingController.swift').read_text()
a = controller.index('struct TilingBarWindow {')
b = controller.index('\n/// Automatic tiling', a)
snapshot = controller[a:b]
harness = '''
enum AnimationStyle { case liquid, solid }
enum TilingControlBarMode { case fullWidth, hybridNotch }
enum SystemHUDKind { case volume, brightness }
enum AudioOutputKind { case builtin, headphones, external, airplay, carplay, bluetooth }
final class AppSettings {
    static let shared = AppSettings()
    var animationStyle: AnimationStyle = .liquid
    var brightFocusAlpha: CGFloat = 1.0
    var dimFocusAlpha: CGFloat = 0.4
    var systemHUDDeviceIcons: Bool = false
    var tilingControlBarDuoBatteryWifi: Bool = false
}
enum IndicatorRenderer {
    static func systemHUDIcon(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?, deviceIcons: Bool, pointSize: CGFloat, color: NSColor) -> NSImage? { nil }
    static func inputSourceHUDIcon(pointSize: CGFloat, color: NSColor) -> NSImage? { nil }
    static func centersSystemHUDIcon(kind: SystemHUDKind) -> Bool { false }
}
final class NetworkStatusMonitor {
    struct Status { var powerOn = true; var connected = false; var hotspot = false }
    static let shared = NetworkStatusMonitor()
    var isRunning = false
    var status = Status()
    func start() { isRunning = true }
}
struct HardwareStats { var batteryPercent: Int? = nil; var isCharging: Bool? = nil }
final class HardwareMonitor { static let shared = HardwareMonitor(); var stats = HardwareStats() }
final class WiFiMenuController {
    static let shared = WiFiMenuController()
    func toggle(below: CGRect, bar: CGRect) {}
}
extension TilingControlBarView {
    func prepareTest(_ action: @escaping () -> Void) {
        actions = [(CGRect(x: 10, y: 10, width: 80, height: 24), action)]
        snapshot = TilingBarSnapshot(displayUUID: "test", spaceNumber: 1, spaceCount: 1,
                                    mode: .splitTree, paused: false, windows: [], focusedStatus: .split)
    }
}
@main struct ButtonTests {
    static func main() {
        let view = TilingControlBarView(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
        var calls = 0
        view.prepareTest { calls += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let inside = CGPoint(x: 30, y: 20)
        let outside = CGPoint(x: 200, y: 20)
        assert(view.acceptsFirstMouse(for: nil))
        view.mouseDown(with: event(.leftMouseDown, inside))
        assert(calls == 0, "commands must not run while the mouse is held")
        view.mouseUp(with: event(.leftMouseUp, inside))
        assert(calls == 1, "release must invoke the command once")
        view.mouseUp(with: event(.leftMouseUp, inside))
        assert(calls == 1, "an unmatched release must do nothing")
        view.mouseDown(with: event(.leftMouseDown, inside))
        view.mouseUp(with: event(.leftMouseUp, outside))
        assert(calls == 1, "dragging out of the button cancels activation")
        view.mouseDown(with: event(.leftMouseDown, outside))
        view.mouseUp(with: event(.leftMouseUp, inside))
        assert(calls == 1, "dragging into a button must not activate it")
        view.mouseDown(with: event(.leftMouseDown, inside))
        view.snapshot = nil
        view.mouseUp(with: event(.leftMouseUp, inside))
        assert(calls == 1, "a removed workspace must not receive an old command")
        print("PASS: tiling buttons activate on release, accept first click, cancel on drag-out and ignore stale release")
    }
}
'''
assert '"Move to Left Column"' in view
assert '"Move to Right Column"' in view
assert 'let hasOtherTiledWindow = snapshot?.windows.contains' in view
assert 'if isColumnTab && hasOtherTiledWindow' in view
assert 'columnItem.state' not in view
assert '"Floating"' in view
assert '"Tabbed"' not in view and '"Split"' not in view
assert 'quitAppAction' in view
assert 'forceQuitAppAction' in view
assert 'Quit App' in view
with tempfile.TemporaryDirectory(prefix='msg-tiling-buttons-') as tmp:
    path = Path(tmp)
    (path / 'test.swift').write_text('import AppKit\n' + easing + pipeline + snapshot + view + harness)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode-beta.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', str(root / 'MSG/TilingLayout.swift'),
                    str(root / 'MSG/TilingDisplayClock.swift'), str(path / 'test.swift'),
                    '-o', str(path / 'test')], env=env, check=True)
    subprocess.run([str(path / 'test')], check=True)
