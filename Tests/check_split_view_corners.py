#!/usr/bin/env python3
"""Exercise production Split View pane identification with synthetic CGS data."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/SpaceWatcher.swift").read_text()
corner_source = (root / "MSG/CornerWindow.swift").read_text()
assert "private final class SplitCornerWindow" in corner_source
assert "NSWindow.Level.popUpMenu.rawValue - 1" in corner_source
assert "splitWindow.setPaneFrames(frames)" in corner_source
assert "splitPaneCornerViews" not in corner_source
start = source.index("    static func splitViewPaneWindowIDsByDisplay(\n")
end = source.index("    /// Exact pane content frames", start)
function = source[start:end]

program = """import Foundation
import CoreGraphics
enum Parser {
    private static let fullscreenSpaceType = 4
""" + function + "}\n" + r'''
let split: [[String: Any]] = [[
    "Display Identifier": "Main",
    "Current Space": [
        "type": 4,
        "TileLayoutManager": [
            "TileSpaces": [
                ["TileWindowID": 77],
                ["TileWindowID": NSNumber(value: 76)]
            ]
        ]
    ]
]]
let parsed = Parser.splitViewPaneWindowIDsByDisplay(
    from: split, primaryUUID: "DISPLAY-A"
)
assert(parsed == ["DISPLAY-A": [77, 76]])

let singleFullscreen: [[String: Any]] = [[
    "Display Identifier": "DISPLAY-A",
    "Current Space": ["type": 4, "fs_wid": 90]
]]
assert(Parser.splitViewPaneWindowIDsByDisplay(
    from: singleFullscreen, primaryUUID: nil
).isEmpty)

let oneTile: [[String: Any]] = [[
    "Display Identifier": "DISPLAY-A",
    "Current Space": [
        "type": 4,
        "TileLayoutManager": ["TileSpaces": [["TileWindowID": 90]]]
    ]
]]
assert(Parser.splitViewPaneWindowIDsByDisplay(
    from: oneTile, primaryUUID: nil
).isEmpty)

let desktop: [[String: Any]] = [[
    "Display Identifier": "DISPLAY-A",
    "Current Space": [
        "type": 0,
        "TileLayoutManager": [
            "TileSpaces": [["TileWindowID": 1], ["TileWindowID": 2]]
        ]
    ]
]]
assert(Parser.splitViewPaneWindowIDsByDisplay(
    from: desktop, primaryUUID: nil
).isEmpty)
print("PASS: only genuine multi-pane fullscreen Split View layouts are selected")
'''

with tempfile.TemporaryDirectory(prefix="msg-split-corners-") as tmp:
    path = Path(tmp) / "main.swift"
    path.write_text(program)
    binary = str(Path(tmp) / "test")
    developer = Path("/Applications/Xcode.app/Contents/Developer")
    swiftc = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    sdk = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    subprocess.run([str(swiftc), str(path), "-sdk", str(sdk), "-o", binary], check=True)
    subprocess.run([binary], check=True)
