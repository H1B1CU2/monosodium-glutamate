import AppKit
import CoreGraphics

let screens = NSScreen.screens
for (i, screen) in screens.enumerated() {
    print("Screen \(i):")
    print("  Frame: \(screen.frame)")
    if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        print("  Display ID: \(displayID)")
        if let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = uuidUnmanaged.takeRetainedValue()
            let uuidString = CFUUIDCreateString(nil, uuid) as String?
            print("  UUID: \(uuidString ?? "nil")")
        }
    }
}
