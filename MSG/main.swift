import AppKit
import Darwin

// Disable stdout buffering so diagnostics appear immediately when
// running from terminal or redirecting to a file.
setbuf(__stdoutp, nil)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
