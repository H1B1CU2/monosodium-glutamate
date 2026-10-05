import AppKit

enum TilingLayoutMode { case masterStack }
enum TilingWindowStatus { case leftTabbed, rightTabbed, split, floating }
extension NSScreen { var uuid: String? { "test-display" } }

// PRODUCTION_TAB_TYPES

final class TestBar {
    var snapshots: [String: TilingBarSnapshot] = [:]
    var screens: [String: NSScreen] = [:]
    // PRODUCTION_TAB_GROUP
}

private func expect(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

@main
struct TilingTabGroupTests {
    static func main() {
        guard let screen = NSScreen.screens.first else { fatalError("No display") }
        let frame = CGRect(x: screen.frame.midX + 20, y: screen.frame.minY + 100,
                           width: 200, height: 300)
        func window(_ id: CGWindowID, space: Int = 1,
                    status: TilingWindowStatus = .rightTabbed) -> TilingBarWindow {
            TilingBarWindow(windowID: id, pid: 123, bundleID: "same.app", name: "App",
                            icon: nil, frame: frame, isFocused: id == 2,
                            isShownInLayout: id == 2, status: status, spaceNumber: space)
        }
        let tabs = [window(1), window(2), window(3), window(4, space: 2),
                    window(5, status: .floating)]
        var foldedIcon = tabs[1]
        foldedIcon.siblingIDs = [1, 3]
        let bar = TestBar()
        bar.screens["test-display"] = screen
        bar.snapshots["test-display"] = TilingBarSnapshot(
            displayUUID: "test-display", spaceNumber: 1, spaceCount: 2,
            mode: .masterStack, paused: false, windows: [foldedIcon],
            focusedStatus: .rightTabbed, scope: .allSpaces, tabWindows: tabs)
        let group = bar.tabGroup(displayUUID: "test-display",
                                 pointer: CGPoint(x: frame.midX, y: frame.midY))
        expect(group?.tabs.map(\.windowID) == [1, 2, 3],
               "All Spaces must expose every same-app column tab, excluding other Spaces and floating windows")
        expect(group?.currentIndex == 1, "The focused unfolded window must anchor the swipe")
        expect(bar.tabGroup(displayUUID: "test-display")?.tabs.count == 3,
               "The default column must use unfolded windows too")
        bar.snapshots["test-display"] = TilingBarSnapshot(
            displayUUID: "test-display", spaceNumber: 1, spaceCount: 2,
            mode: .masterStack, paused: false, windows: Array(tabs.prefix(3)),
            focusedStatus: .rightTabbed)
        expect(bar.tabGroup(displayUUID: "test-display")?.tabs.count == 3,
               "Snapshots without a separate gesture list must retain existing behavior")
        print("TilingTabGroupTests passed")
    }
}
