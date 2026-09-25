#!/usr/bin/env python3
"""Compile the production search, tap routing and takeover rules in isolation.
No global event tap is installed and no system hotkeys are changed.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'MSG/AppSwitcherPreview.swift').read_text()
parts = [
    s[s.index('enum MSGSwitcherSearch {'):s.index('private enum MSGSwitcherSlot:')],
    s[s.index('private enum MSGSwitcherInput {'):s.index('@available(macOS 14.0, *)\nprivate final class MSGWindowSwitcher:')],
    s[s.index('struct MSGSystemShortcutTransition:'):s.index('/// Vorssaint\'s write-ahead ownership model')],
]
tests = r'''
assert(MSGSwitcherSearch.matches(title: "Résumé — Budget", app: "Pages", query: "resume pages"))
assert(MSGSwitcherSearch.matches(title: "หน้าต่าง", app: "MSG", query: "หน้าต่าง"))
assert(!MSGSwitcherSearch.matches(title: "Budget", app: "Pages", query: "budget safari"))
assert(MSGSwitcherSearch.matches(title: "Anything", app: "App", query: "  "))
assert(MSGSwitcherSearch.sanitized("a\n\tb\u{7F}c") == "abc")
assert(MSGSwitcherSearch.next(0, delta: -1, count: 3) == 2)
assert(MSGSwitcherSearch.next(2, delta: 1, count: 3, wrapping: false) == 2)
assert(MSGSwitcherSearch.next(9, delta: 1, count: 0) == 0)
for count in 1...20 {
    for delta in -30...30 {
        assert((0..<count).contains(MSGSwitcherSearch.next(0, delta: delta, count: count)))
    }
}
assert(MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 48, modifiers: 0x100000))
assert(MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 48, modifiers: 0x120000))
assert(MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 48, modifiers: 0x100))
assert(MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 48, modifiers: 0x300))
assert(!MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 12, modifiers: 0x100000))
assert(!MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: 48, modifiers: 0x140000))
let transition = MSGSystemShortcutTakeoverSupport.transition(from: [1], to: [1, 2], currentlyEnabled: [2])
assert(transition.suppress == [2] && transition.restore.isEmpty)
let native = MSGSystemShortcutTakeoverSupport.transition(from: [1, 2], to: [], currentlyEnabled: [])
assert(native.suppress.isEmpty && native.restore == [1, 2])
let untouched = MSGSystemShortcutTakeoverSupport.transition(from: [], to: [1, 2], currentlyEnabled: [])
assert(untouched.suppress.isEmpty && untouched.restore.isEmpty)
var writes: [Set<Int32>] = []
let failedDisable = MSGSystemShortcutTakeoverSupport.apply(.init(suppress: [1], restore: []), owned: [],
    setEnabled: { _, _ in false }, persist: { writes.append($0) })
assert(failedDisable.isEmpty && writes == [[1], []])
let failedRestore = MSGSystemShortcutTakeoverSupport.apply(native, owned: [1, 2],
    setEnabled: { id, _ in id == 1 }, persist: { _ in })
assert(failedRestore == [2])
let recovery = MSGSystemShortcutTakeoverSupport.recoveryTransition(from: [1, 2], keeping: [])
assert(recovery.suppress.isEmpty && recovery.restore == [1, 2])

@available(macOS 14.0, *)
private extension MSGSwitcherEventTap {
    func checkMousePassThrough() {
        // Even while another thread owns lifecycle state, mouse events must
        // bypass the lock and never enter the suppressing tap's event mask.
        lock.lock(); defer { lock.unlock() }
        for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                  .leftMouseUp, .rightMouseUp, .mouseMoved, .scrollWheel] {
            assert(Self.eventMask & (CGEventMask(1) << type.rawValue) == 0)
            assert(!feed(type))
        }
    }
    func feed(_ type: CGEventType, code: CGKeyCode = 0, flags: CGEventFlags = [], text: String = "") -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)!
        event.flags = flags
        if !text.isEmpty {
            let chars = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        }
        return route(type, event) == nil
    }
}
if #available(macOS 14.0, *) {
    var inputs: [(Int, MSGSwitcherInput)] = []
    let tap = MSGSwitcherEventTap { inputs.append(($0, $1)) }
    tap.checkMousePassThrough()
    assert(!tap.feed(.keyDown, code: 3, flags: .maskCommand, text: "f"))
    assert(!tap.feed(.keyDown, code: 48, flags: [.maskCommand, .maskAlternate]))
    assert(tap.feed(.keyDown, code: 48, flags: .maskCommand))
    tap.checkMousePassThrough()
    assert(tap.feed(.keyDown, code: 12, flags: .maskCommand, text: "q"))
    assert(tap.feed(.keyUp, code: 12, flags: .maskCommand))
    assert(!tap.feed(.flagsChanged, flags: []))
    tap.checkMousePassThrough()
    assert(tap.feed(.keyUp, code: 48))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 3)
    if case .begin(false) = inputs[0].1 {} else { fatalError("Missing Cmd-Tab start") }
    if case .key(12, let text, _, _) = inputs[1].1 { assert(text == "q") } else { fatalError("Search key lost") }
    if case .commit = inputs[2].1 {} else { fatalError("Quick release did not commit") }
    assert(inputs.allSatisfy { $0.0 == 1 })
    assert(!tap.feed(.keyDown, code: 0, text: "a"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 4)
    if case .cancel = inputs[3].1 {} else { fatalError("Post-release typing must cancel a slow pending switch") }
    inputs.removeAll()
    assert(tap.feed(.keyDown, code: 48, flags: [.maskCommand, .maskShift]))
    assert(tap.feed(.keyDown, code: 53, flags: .maskCommand))
    assert(!tap.feed(.keyDown, code: 3, flags: .maskCommand, text: "f"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 2 && inputs[0].0 == 2)
    if case .begin(true) = inputs[0].1 {} else { fatalError("Reverse navigation lost") }
    if case .cancel = inputs[1].1 {} else { fatalError("Escape did not cancel") }
    // Test Cmd+Shift backward navigation while owned
    inputs.removeAll()
    assert(tap.feed(.keyDown, code: 48, flags: .maskCommand))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 1 && inputs[0].0 == 3)
    if case .begin(false) = inputs[0].1 {} else { fatalError("Cmd-Tab begin failed") }
    // Press Shift while holding Cmd -> backward step
    assert(!tap.feed(.flagsChanged, flags: [.maskCommand, .maskShift]))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 2)
    if case .key(48, _, true, false) = inputs[1].1 {} else { fatalError("Cmd+Shift backward navigation failed") }
    // Press Tab within chord window (< 200ms) -> swallowed
    assert(tap.feed(.keyDown, code: 48, flags: [.maskCommand, .maskShift]))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 2)
    // Release Shift
    assert(!tap.feed(.flagsChanged, flags: [.maskCommand]))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 2)
    // Press ` (code 50, grave) -> backward key
    assert(tap.feed(.keyDown, code: 50, flags: .maskCommand))
    assert(tap.feed(.keyUp, code: 50, flags: .maskCommand))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 3)
    if case .key(50, _, _, _) = inputs[2].1 {} else { fatalError("Backtick/tilde backward key failed") }
    // Release Command -> commit
    assert(!tap.feed(.flagsChanged, flags: []))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(inputs.count == 4)
    if case .commit = inputs[3].1 {} else { fatalError("Commit failed") }
    tap.stop()
    assert(!tap.feed(.keyDown, code: 48, flags: .maskCommand))
}
print("PASS: mouse bypass with lock held, search, navigation, event routing, quick release, cancellation, and hotkey ownership recovery")
'''
with tempfile.TemporaryDirectory(prefix='msg-switcher-tests-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text('import AppKit\nimport ApplicationServices\nimport Foundation\n' + '\n'.join(parts) + tests)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', str(path), '-sdk', sdk, '-target', 'arm64-apple-macos14.0', '-o', str(Path(tmp)/'tests')], env=env, check=True)
    subprocess.run([str(Path(tmp)/'tests')], check=True, timeout=20)

assert 'var category: String = "Float"' in s
assert 'case "Tab", "Tabbed": return 1' in s
assert 'case "Float", "Floating": return 4' in s
assert 'case "Tabbed": it.category = "Tab"' in s
assert 'case "Floating": it.category = "Float"' in s
assert 'let displayTitle = (title == "Tabbed") ? "Tab" : ((title == "Floating") ? "Float" : title)' in s
print("PASS: switcher category labels renamed to Tab and Float")
