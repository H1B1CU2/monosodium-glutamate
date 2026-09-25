#!/usr/bin/env python3
"""Check the production border gate and motion curve without moving windows."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'MSG/AppSwitcherPreview.swift').read_text()
move_start = s.index('    private func movePanel(to screen:')
callback_start = s.index('        let timer = MSGSwitcherDisplayAnimation', move_start)
callback_end = s.index('        moveTimer = timer', callback_start)
callback = s[callback_start:callback_end]
assert 'snapshot(' not in s[move_start:callback_end], 'Snapshot rendering must not block display-link frames'
assert 'layoutSubtreeIfNeeded' not in callback, 'Layout must be prepared before movement'
start = s.index('    static func previewCaptureOrder(')
end = s.index('    private var moveTimer:', start)
source = 'import AppKit\nenum Motion {\n' + s[start:end] + '''
static func run() {
    assert(previewCaptureOrder(selected: 2, visible: [1, 2], all: [1, 2, 3, 3, 4]) == [2, 1, 3, 4])
    assert(previewCaptureOrder(selected: nil, visible: [], all: [3, 3, 4]) == [3, 4])
    assert(previewCaptureOrder(selected: 3, visible: [3, 4], all: [1, 2, 3, 4]) == [3, 4, 1, 2])
    let right = CGRect(x: 100, y: 0, width: 100, height: 100)
    assert(!hasCrossedDisplay(CGPoint(x: 99.9, y: 50), destination: right))
    assert(hasCrossedDisplay(CGPoint(x: 100.1, y: 50), destination: right))
    let left = CGRect(x: -100, y: 0, width: 100, height: 100)
    assert(!hasCrossedDisplay(CGPoint(x: 0.1, y: 50), destination: left))
    assert(hasCrossedDisplay(CGPoint(x: -0.1, y: 50), destination: left))
    let above = CGRect(x: 0, y: 100, width: 100, height: 100)
    let below = CGRect(x: 0, y: -100, width: 100, height: 100)
    assert(!hasCrossedDisplay(CGPoint(x: 50, y: 99), destination: above))
    assert(hasCrossedDisplay(CGPoint(x: 50, y: 101), destination: above))
    assert(!hasCrossedDisplay(CGPoint(x: 50, y: 1), destination: below))
    assert(hasCrossedDisplay(CGPoint(x: 50, y: -1), destination: below))
    assert(!hasCrossedDisplay(CGPoint(x: 101, y: 101), destination: right))
    assert(travelCurve(-1) == 0 && travelCurve(2) == 1)
    var previous: CGFloat = 0
    for step in 0...1000 {
        let value = travelCurve(CGFloat(step) / 1000)
        assert(value >= previous && value <= 1)
        previous = value
    }
    assert(abs(travelCurve(0.5) - 0.5) < 0.00001)
    assert(travelProgress(-1) == 0 && travelProgress(2) == 1)
    assert(travelProgress(1.0 / 60 / 0.3) > 0.15)
    previous = 0
    for step in 0...1000 {
        let value = travelProgress(CGFloat(step) / 1000)
        assert(value >= previous && value <= 1)
        previous = value
    }
    print("PASS: captures cover both displays in either starting direction; centre crossing in four directions, offset displays, monotonic bounded motion")
}
}
Motion.run()
'''
with tempfile.TemporaryDirectory(prefix='msg-morph-test-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    binary = str(Path(tmp) / 'test')
    subprocess.run(['xcrun', 'swiftc', str(path), '-sdk', sdk, '-o', binary], env=env, check=True)
    subprocess.run([binary], check=True)
