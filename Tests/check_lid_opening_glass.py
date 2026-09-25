#!/usr/bin/env python3
"""Exercise the production lid-angle-to-glass mapping."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/LidOpeningGlass.swift").read_text()
start = source.index("enum LidGlassMapping {")
end = source.index("// MARK: - Lid angle sensor", start)
mapping = source[start:end]

program = "import Foundation\nimport CoreGraphics\n" + mapping + r'''
func close(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.0001) {
    assert(abs(value - expected) <= tolerance, "\(value) != \(expected)")
}

close(LidGlassMapping.openness(for: -20), 0)
close(LidGlassMapping.openness(for: 15), 0)
close(LidGlassMapping.openness(for: 70), 0.5)
close(LidGlassMapping.openness(for: 125), 1)
close(LidGlassMapping.openness(for: 180), 1)

let closed = LidGlassMapping.intensity(for: 15)
let half = LidGlassMapping.intensity(for: 70)
let open = LidGlassMapping.intensity(for: 125)
assert(closed == 1)
assert(closed >= half && half > open)
assert(open == 0)
close(LidGlassMapping.intensity(forOpenness: -1), 1)
close(LidGlassMapping.intensity(forOpenness: 1), 0)

// The plate remains optically present through most of the fold, then
// materializes near the fully-open endpoint.
close(LidGlassMapping.materialization(forOpenness: 0.70), 0)
assert(LidGlassMapping.materialization(forOpenness: 0.85) > 0)
close(LidGlassMapping.materialization(forOpenness: 1), 1)

close(LidGlassMapping.foldAngleDegrees(forOpenness: 0), 82)
close(LidGlassMapping.foldAngleDegrees(forOpenness: 1), 0)
assert(LidGlassMapping.foldAngleDegrees(forOpenness: 0.25)
       > LidGlassMapping.foldAngleDegrees(forOpenness: 0.75))

close(LidGlassMapping.rimIntensity(forOpenness: 0), 0)
assert(LidGlassMapping.rimIntensity(forOpenness: 0.5) > 0)
close(LidGlassMapping.rimIntensity(forOpenness: 1), 0)
print("PASS: Duo fold, materialization, and rim mappings follow hinge openness")
'''

with tempfile.TemporaryDirectory(prefix="msg-lid-glass-") as tmp:
    path = Path(tmp) / "main.swift"
    path.write_text(program)
    binary = str(Path(tmp) / "test")
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    env.pop("SDKROOT", None)
    subprocess.run(["xcrun", "swiftc", str(path), "-o", binary], env=env, check=True)
    subprocess.run([binary], check=True)
