import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TrackpadSwipeMonitorTests {
    static func main() {
        expect(TrackpadSwipeMonitor.canRearm(withDownCount: 2, verticalCount: 3,
                                              horizontalCount: 4),
               "partial lift should allow a new three-finger swipe")
        expect(!TrackpadSwipeMonitor.canRearm(withDownCount: 3, verticalCount: 3,
                                               horizontalCount: 4),
               "full contact must not restart the same gesture")
        expect(TrackpadSwipeMonitor.canRearm(withDownCount: 3, verticalCount: 0,
                                              horizontalCount: 4),
               "horizontal-only mode should rearm below four fingers")
        expect(!TrackpadSwipeMonitor.canRearm(withDownCount: 4, verticalCount: 0,
                                               horizontalCount: 4),
               "horizontal-only mode must not restart at its active count")
        print("TrackpadSwipeMonitorTests passed")
    }
}
