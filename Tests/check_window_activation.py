#!/usr/bin/env python3
"""Validate the production focus-event payload without posting system events."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'MSG/WindowPreviewCapture.swift').read_text()
start = source.index('    private static func makeKeyWindow(')
end = source.index('    // MARK: Placeholder', start)
method = source[start:end]
focus_start = source.index('    private static func requestWindowFocus(')
focus_end = source.index('    /// Presses the AX close button', focus_start)
focus_method = source[focus_start:focus_end]
visibility_start = source.index('    private static func windowIsOnVisibleSpace(')
visibility_end = source.index('    /// Resolves the current managed Space', visibility_start)
visibility_method = source[visibility_start:visibility_end]
harness = r'''import Foundation
import CoreGraphics
struct ProcessSerialNumber {}
var memberships: [Int] = []
var displaySpaces: [[String: Any]]? = nil
func CGSMainConnectionID() -> Int { 0 }
func CGSCopyManagedDisplaySpaces(_ connection: Int) -> Any? { displaySpaces }
var records: [[UInt8]] = []
let noErr: Int32 = 0
var processResult: Int32 = 0
var focusResult: CGError = .success
var focusRequests: [CGWindowID] = []
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> Int32 { processResult }
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID, _ options: UInt32) -> CGError {
    focusRequests.append(windowID)
    return focusResult
}
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafePointer<UInt8>) -> Int32 {
    records.append(Array(UnsafeBufferPointer(start: bytes, count: 0xf8)))
    return 0
}
enum FocusTests {
''' + method + focus_method + visibility_method + r'''
    static func spacesForWindow(_ id: CGWindowID) -> [Int] { memberships }
    static func run() {
        assert(windowIsOnVisibleSpace(1) == nil)
        memberships = [5]
        displaySpaces = [["Current Space": ["ManagedSpaceID": 3]], ["Current Space": ["id64": 5]]]
        assert(windowIsOnVisibleSpace(1) == true)
        memberships = [7]
        assert(windowIsOnVisibleSpace(1) == false)
        memberships = [3, 7]
        assert(windowIsOnVisibleSpace(1) == true)
        displaySpaces = [["Current Space": [:]]]
        assert(windowIsOnVisibleSpace(1) == nil)
        var psn = ProcessSerialNumber()
        let windowID: CGWindowID = 0x12345678
        makeKeyWindow(psn: &psn, windowID: windowID)
        guard records.count == 2, records.map({ $0[0x08] }) == [0x01, 0x02] else {
            print("FAIL: focus must post 0x01 then 0x02; got", records.map { $0[0x08] })
            exit(1)
        }
        for bytes in records {
            guard bytes[0x04] == 0xf8, bytes[0x3a] == 0x10,
                  Array(bytes[0x3c..<0x40]) == [0x78, 0x56, 0x34, 0x12],
                  bytes[0x20..<0x30].allSatisfy({ $0 == 0xff }) else {
                print("FAIL: focus payload damaged")
                exit(1)
            }
        }
        records.removeAll()
        assert(requestWindowFocus(pid: 123, windowID: windowID))
        assert(focusRequests == [windowID] && records.map { $0[0x08] } == [1, 2])
        records.removeAll(); focusRequests.removeAll()
        focusResult = .failure
        assert(!requestWindowFocus(pid: 123, windowID: windowID))
        assert(records.isEmpty && focusRequests == [windowID])
        focusRequests.removeAll(); processResult = -1
        assert(!requestWindowFocus(pid: 123, windowID: windowID))
        assert(focusRequests.isEmpty && records.isEmpty)
        processResult = 0
        assert(!requestWindowFocus(pid: 123, windowID: 0))
        assert(focusRequests.isEmpty && records.isEmpty)
        print("PASS: multi-display Space visibility, unknown Space data, exact-window focus, rejected activation, event order and payload; no events posted")
    }
}
FocusTests.run()
'''
with tempfile.TemporaryDirectory(prefix='msg-activation-tests-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text(harness)
    executable = Path(tmp) / 'tests'
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', str(path), '-sdk', sdk,
                    '-target', 'arm64-apple-macos14.0', '-o', str(executable)], env=env, check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
