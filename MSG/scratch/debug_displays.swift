import AppKit
import CoreGraphics

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

let cid = CGSMainConnectionID()
let screens = NSScreen.screens
print("NSScreens count: \(screens.count)")
for (i, s) in screens.enumerated() {
    let dID = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    if let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(dID) {
        let uuid = uuidUnmanaged.takeRetainedValue()
        let uuidString = CFUUIDCreateString(nil, uuid) as String?
        print("Screen \(i): ID=\(dID), UUID=\(uuidString ?? "nil"), OriginX=\(s.frame.origin.x)")
    } else {
        print("Screen \(i): ID=\(dID), UUID=nil, OriginX=\(s.frame.origin.x)")
    }
}

if let raw = CGSCopyManagedDisplaySpaces(cid), let dicts = raw as? [[String: Any]] {
    print("\nCGSCopyManagedDisplaySpaces dicts: \(dicts.count)")
    for (i, d) in dicts.enumerated() {
        let ident = d["Display Identifier"] as? String ?? "nil"
        print("Dict \(i): Display Identifier=\(ident)")
    }
} else {
    print("Failed to get spaces")
}
