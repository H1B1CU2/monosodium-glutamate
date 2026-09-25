#!/usr/bin/env python3
"""Exercise the production Space ownership gate without changing display focus."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/SpaceWatcher.swift").read_text()
start = source.index("    static func isSameDisplaySpaceSwitch(\n")
end = source.index("    /// CGS space type", start)
program = "import Foundation\nenum Gate {\n" + source[start:end] + "}\n" + r'''
let displays: [[String: Any]] = [
    ["Spaces": [["ManagedSpaceID": 11], ["ManagedSpaceID": 12]]],
    ["Spaces": [["ManagedSpaceID": 21], ["ManagedSpaceID": 22]]]
]
func check(_ old: Int, _ new: Int, _ expected: Bool) {
    assert(Gate.isSameDisplaySpaceSwitch(from: old, to: new, displays: displays) == expected)
}
check(11, 21, false) // Focus moves to external monitor.
check(21, 11, false) // Focus returns to built-in display.
check(11, 12, true)  // Actual Space change on built-in display.
check(21, 22, true)  // Actual Space change on external display.
check(11, 11, false)
check(0, 11, false)
check(11, 99, false) // Unknown/removed Space must not arm an animation.
assert(!Gate.isSameDisplaySpaceSwitch(from: 11, to: 12, displays: []))
assert(!Gate.isSameDisplaySpaceSwitch(from: 11, to: 12, displays: [["Spaces": "unavailable"]]))
print("PASS: monitor focus changes ignored; same-display Space changes preserved")
'''
with tempfile.TemporaryDirectory(prefix="msg-corner-focus-") as tmp:
    path = Path(tmp) / "main.swift"
    path.write_text(program)
    binary = str(Path(tmp) / "test")
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", str(path), "-o", binary], env=env, check=True)
    subprocess.run([binary], check=True)
