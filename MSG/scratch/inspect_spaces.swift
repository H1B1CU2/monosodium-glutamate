import AppKit
import CoreGraphics

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

let cid = CGSMainConnectionID()
if let raw = CGSCopyManagedDisplaySpaces(cid) {
    print(raw)
} else {
    print("Failed to get spaces")
}
