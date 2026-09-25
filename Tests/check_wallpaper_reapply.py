#!/usr/bin/env python3
"""Compile the production wallpaper write gate without changing the desktop."""

from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/WallpaperEngine.swift").read_text()
start = source.index("    static func needsWallpaperWrite(")
end = source.index("\n    /// Writes the wallpaper URL", start)
gate = source[start:end]

harness = f"""
import Foundation

enum WallpaperWriteGate {{
{gate}
}}

let baked = URL(fileURLWithPath: "/tmp/msg-wallpaper/baked.png")
let sameSpelling = URL(fileURLWithPath: "/tmp/msg-wallpaper/baked.png")
let equivalentSpelling = URL(fileURLWithPath: "/tmp/msg-wallpaper/cache/../baked.png")
let other = URL(fileURLWithPath: "/tmp/msg-wallpaper/other.png")

assert(!WallpaperWriteGate.needsWallpaperWrite(current: sameSpelling, target: baked))
assert(!WallpaperWriteGate.needsWallpaperWrite(current: equivalentSpelling, target: baked))
assert(WallpaperWriteGate.needsWallpaperWrite(current: other, target: baked))
assert(WallpaperWriteGate.needsWallpaperWrite(current: nil, target: baked))
assert(!WallpaperWriteGate.needsWallpaperWrite(
    current: URL(string: "https://example.com/wallpaper")!,
    target: URL(string: "https://example.com/wallpaper")!
))
assert(WallpaperWriteGate.needsWallpaperWrite(
    current: URL(string: "https://example.com/old")!,
    target: URL(string: "https://example.com/new")!
))
print("PASS: identical wallpaper retries are skipped; real changes still write")
"""

with tempfile.TemporaryDirectory(prefix="msg-wallpaper-tests-") as tmp:
    main = Path(tmp) / "main.swift"
    main.write_text(harness)
    executable = Path(tmp) / "tests"
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True
    ).strip()
    subprocess.run(
        [
            "xcrun", "--sdk", "macosx", "swiftc", str(main),
            "-sdk", sdk, "-target", "arm64-apple-macos14.0", "-o", str(executable),
        ],
        env=env,
        check=True,
    )
    subprocess.run([str(executable)], check=True, timeout=20)
