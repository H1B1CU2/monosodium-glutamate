#!/usr/bin/env python3
"""Check launch-only one-app-per-Deskspace routing and its pure policy."""

from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / "MSG/TilingController.swift").read_text()
settings = (root / "MSG/Settings.swift").read_text()
pane = (root / "MSG/TilingPane.swift").read_text()

assert 'static let tilingOneAppPerDeskspace' in settings
assert 'Key.tilingOneAppPerDeskspace:  true' in settings
assert '"One app per Deskspace"' in pane
assert 'forName: NSWorkspace.didLaunchApplicationNotification' in controller
assert 'handleNewApplicationLaunch(app)' in controller
assert 'shouldCreateDeskspaceForNewApp(' in controller
assert 'window.pid != pid' in controller
assert 'isOnManagedSpace: sourceSpaceID' in controller
assert 'addSpace(displayUUID: displayUUID)' in controller
assert 'settings.tilingAutoDeleteEmptySpaces || settings.tilingOneAppPerDeskspace' in controller
assert 'a later user move may combine' in controller

test_source = r'''
import CoreGraphics

@main struct AppSpaceIsolationTests {
    static func main() {
        assert(!TilingLayout.shouldCreateDeskspaceForNewApp(
            hasUsableWindow: false,
            currentSpaceIsFullscreen: false,
            hasOtherApplication: true
        ))
        assert(!TilingLayout.shouldCreateDeskspaceForNewApp(
            hasUsableWindow: true,
            currentSpaceIsFullscreen: true,
            hasOtherApplication: true
        ))
        assert(!TilingLayout.shouldCreateDeskspaceForNewApp(
            hasUsableWindow: true,
            currentSpaceIsFullscreen: false,
            hasOtherApplication: false
        ))
        assert(TilingLayout.shouldCreateDeskspaceForNewApp(
            hasUsableWindow: true,
            currentSpaceIsFullscreen: false,
            hasOtherApplication: true
        ))
        print("PASS: new apps reuse an empty Deskspace and isolate only from an occupied one")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="msg-app-space-isolation-") as tmp:
    main = Path(tmp) / "test.swift"
    main.write_text(test_source)
    executable = Path(tmp) / "tests"
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True
    ).strip()
    subprocess.run(
        [
            "xcrun", "--sdk", "macosx", "swiftc",
            str(root / "MSG/TilingLayout.swift"), str(main),
            "-sdk", sdk, "-target", "arm64-apple-macos14.0",
            "-o", str(executable),
        ],
        env=env,
        check=True,
    )
    subprocess.run([str(executable)], check=True, timeout=20)
