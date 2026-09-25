#!/usr/bin/env python3
"""Exercise the production window filter without controlling any windows."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'MSG/WindowPreviewCapture.swift').read_text()
start = source.index('    private static func isPlausiblyReal(')
end = source.index('    /// TV\'s fullscreen player', start)
predicate = source[start:end]
candidate_start = source.index('        let filteredCandidates = candidates.filter { c in')
candidate_end = source.index('\n\n', candidate_start)
candidate_filter = source[candidate_start:candidate_end]
harness = '''
import CoreGraphics
enum FilterTests {
    struct Entry {
        let id: CGWindowID
        let title: String?
        let onScreen: Bool
    }
    static func isManagedFullscreenWindow(_ id: CGWindowID) -> Bool { id == 218 }
    static func spacesForWindow(_ id: CGWindowID) -> [Int] { id == 99 ? [] : [5] }
    static func windowTags(_ id: CGWindowID) -> (low: UInt32, high: UInt32)? {
        if id == 91 { return (0x400000, 0) } // ordered-out ghost (bit 22 set, bit 13 clear)
        if id == 177 { return (0x480001, 0) } // real Gemini chat when parked on another Space
        if id == 74 { return (0x482001, 50331649) } // TV library on another Space
        if id == 99 { return (0x482001, 0) } // ordered-in but no Space
        if id == 1483 { return (0x402000, 0) } // ordered-in real (bit 22 and 13 set)
        if id == 999 { return (1 << 18, 0) } // cycle excluded (bit 18 set)
        return nil
    }
''' + predicate + '''
    struct Candidate {
        let id: CGWindowID
        let title: String?
        let bounds: CGRect
    }
    static func checkNotchCandidates() {
        let candidates = [
            Candidate(id: 175, title: "Gemini Onboarding", bounds: CGRect(x: 0, y: 0, width: 704, height: 520)),
            Candidate(id: 177, title: nil, bounds: CGRect(x: 0, y: 0, width: 598, height: 536)),
            Candidate(id: 178, title: "Chat", bounds: CGRect(x: 0, y: 0, width: 600, height: 500))
        ]
        let validIDs: Set<CGWindowID> = [177, 178]
''' + candidate_filter + '''
        assert(filteredCandidates.map { $0.id } == [177, 178])
    }
    static func run() {
        checkNotchCandidates()
        let gemini = "com.google.GeminiMacOS"
        for title in ["Computer Use", "Computer Use Controls"] {
            for visible in [true, false] {
                let utility = Entry(id: 1489, title: title, onScreen: visible)
                assert(!isPlausiblyReal(utility, axIDs: [1489], ownerBundleID: "com.openai.codex"))
                assert(isPlausiblyReal(utility, axIDs: [1489], ownerBundleID: "other.app"))
            }
        }
        assert(isPlausiblyReal(Entry(id: 1089, title: "ChatGPT", onScreen: false),
                              axIDs: [], ownerBundleID: "com.openai.codex"))
        let tv = "com.apple.TV"
        assert(isPlausiblyReal(Entry(id: 218, title: nil, onScreen: false),
                              axIDs: [74], ownerBundleID: tv))
        assert(!isPlausiblyReal(Entry(id: 220, title: nil, onScreen: false),
                               axIDs: [74], ownerBundleID: tv))
        assert(!isPlausiblyReal(Entry(id: 218, title: nil, onScreen: false),
                               axIDs: [74], ownerBundleID: "other.app"))
        let library = Entry(id: 74, title: "TV", onScreen: false)
        assert(isPlausiblyReal(library, axIDs: [218], ownerBundleID: tv))
        assert(isPlausiblyReal(Entry(id: 218, title: nil, onScreen: true),
                              axIDs: [218], ownerBundleID: tv))
        assert(!isPlausiblyReal(library, axIDs: [218], ownerBundleID: "other.app"))
        assert(!isPlausiblyReal(Entry(id: 91, title: "TV", onScreen: false),
                               axIDs: [218], ownerBundleID: tv))
        assert(!isPlausiblyReal(Entry(id: 99, title: "TV", onScreen: false),
                               axIDs: [218], ownerBundleID: tv))
        assert(!isPlausiblyReal(Entry(id: 999, title: "TV", onScreen: false),
                               axIDs: [218], ownerBundleID: tv))
        let line = "jp.naver.line.mac"
        let parked = Entry(id: 91, title: nil, onScreen: false)
        // LINE ghost window 91 has bit 22 set and bit 13 clear -> filtered out
        assert(!isPlausiblyReal(parked, axIDs: [], ownerBundleID: line))
        let realLine = Entry(id: 1483, title: "Chat", onScreen: false)
        assert(isPlausiblyReal(realLine, axIDs: [], ownerBundleID: line))
        // Window cycle excluded tag (bit 18)
        let excluded = Entry(id: 999, title: "Overlay", onScreen: true)
        assert(!isPlausiblyReal(excluded, axIDs: [999], ownerBundleID: "app"))
        let leftover = Entry(id: 175, title: "Gemini Onboarding", onScreen: false)
        // AX failure used to resurrect the dismissed onboarding surface.
        assert(!isPlausiblyReal(leftover, axIDs: [], ownerBundleID: gemini))
        assert(!isPlausiblyReal(leftover, axIDs: [177], ownerBundleID: gemini))
        // Gemini Onboarding is permanently excluded as a utility surface
        assert(!isPlausiblyReal(leftover, axIDs: [175], ownerBundleID: gemini))
        assert(!isPlausiblyReal(Entry(id: 175, title: leftover.title, onScreen: true),
                               axIDs: [], ownerBundleID: gemini))
        // Preserve Gemini's real off-Space chat window even when AX disappears
        // and its generic AppKit ordered-in bit is cleared by WindowServer.
        assert(isPlausiblyReal(Entry(id: 177, title: nil, onScreen: false),
                              axIDs: [], ownerBundleID: gemini))
        assert(isPlausiblyReal(leftover, axIDs: [], ownerBundleID: "other.app"))
        assert(!isPlausiblyReal(Entry(id: 99, title: nil, onScreen: false),
                                axIDs: [], ownerBundleID: gemini))
        print("PASS: TV library/player retained; LINE/Gemini stale windows and ChatGPT control utilities excluded; real windows retained")
    }
}
FilterTests.run()
'''
with tempfile.TemporaryDirectory(prefix='msg-window-filter-tests-') as tmp:
    path = Path(tmp) / 'main.swift'
    path.write_text(harness)
    executable = Path(tmp) / 'tests'
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', str(path), '-sdk', sdk,
                    '-target', 'arm64-apple-macos14.0', '-o', str(executable)], env=env, check=True)
    subprocess.run([str(executable)], check=True, timeout=20)
