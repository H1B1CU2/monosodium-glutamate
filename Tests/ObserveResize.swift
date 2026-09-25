import AppKit

// Read-only WindowServer geometry sampling. No titles, captures or AX writes.
// Usage: ObserveResize seconds; redirect stdout to retain a local trace.
let duration = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let start = ProcessInfo.processInfo.systemUptime
print("elapsed,id,owner,x,y,width,height,right,bottom,mouseDown")
var previous: [UInt32: CGRect] = [:]
while ProcessInfo.processInfo.systemUptime - start < duration {
    let now = ProcessInfo.processInfo.systemUptime - start
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
    for window in windows {
        guard window[kCGWindowLayer as String] as? Int == 0,
              let id = window[kCGWindowNumber as String] as? UInt32,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              previous[id] != rect else { continue }
        previous[id] = rect
        let owner = (window[kCGWindowOwnerName as String] as? String ?? "").replacingOccurrences(of: ",", with: " ")
        print("\(now),\(id),\(owner),\(rect.minX),\(rect.minY),\(rect.width),\(rect.height),\(rect.maxX),\(rect.maxY),\(NSEvent.pressedMouseButtons & 1 != 0)")
    }
    Thread.sleep(forTimeInterval: 1.0 / 120.0)
}
