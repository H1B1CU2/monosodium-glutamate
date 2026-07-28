import AppKit
import SwiftUI

// MARK: - TrayPanel

@available(macOS 14.0, *)
final class TrayPanel {

    private(set) var state: TrayState
    private var panel: NSPanel?
    private var hosting: NSHostingController<TrayHUDView>?
    private var cmdMonitor: Any?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapUserInfo: Unmanaged<AnyObject>?
    private var healthTimer: Timer?

    init(state: TrayState) {
        self.state = state
    }

    // MARK: - Hotkey (CGEventTap — the only way to intercept ⌘⇥)

    func registerHotkey() {
        guard eventTap == nil else { return }
        createTap()
        startHealthTimer()
    }

    private func createTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        // passRetained keeps self alive across the C callback boundary
        let retained = Unmanaged.passRetained(self as AnyObject)
        tapUserInfo = retained

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let ptr = userInfo else { return Unmanaged.passRetained(event) }
                let panel = Unmanaged<TrayPanel>.fromOpaque(ptr).takeUnretainedValue()

                // Re-enable if macOS disabled our tap
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = panel.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passRetained(event)
                }

                // ⎋ while HUD visible → instant dismiss, no activation
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventKeycode) == 53,
                   panel.state.isVisible {
                    DispatchQueue.main.async { panel.hide(activate: false) }
                    return nil
                }

                // ⌘ released while HUD is visible → activate + dismiss
                if type == .flagsChanged,
                   !event.flags.contains(.maskCommand),
                   panel.state.isVisible {
                    DispatchQueue.main.async { panel.hide(activate: true) }
                    return Unmanaged.passRetained(event)
                }

                // ⇧ press while ⌘ held + HUD visible → navigate backward
                if type == .flagsChanged,
                   event.flags.contains(.maskCommand),
                   event.flags.contains(.maskShift),
                   panel.state.isVisible {
                    DispatchQueue.main.async { panel.state.selectPrev() }
                    return nil
                }

                guard type == .keyDown,
                      event.getIntegerValueField(.keyboardEventKeycode) == 48,
                      event.flags.contains(.maskCommand) else {
                    return Unmanaged.passRetained(event)
                }

                // ⌘⇥ while visible → cycle; first press → show
                let goBack = event.flags.contains(.maskShift)
                DispatchQueue.main.async {
                    if panel.state.isVisible {
                        goBack ? panel.state.selectPrev() : panel.state.selectNext()
                    } else {
                        panel.show(goBack: goBack)
                    }
                }
                return nil  // suppress system switcher
            },
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            tapUserInfo = nil
            NSLog("Tray: CGEventTap creation failed — is Accessibility permission granted?")
            // Retry after 5 s in case permission was just granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.createTap() }
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapSource = src
        NSLog("Tray: event tap registered")
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("Tray: tap disabled — attempting re-enable")
                CGEvent.tapEnable(tap: tap, enable: true)
                // If still dead after re-enable, tear down and recreate the whole tap.
                if !CGEvent.tapIsEnabled(tap: tap) {
                    NSLog("Tray: re-enable failed — recreating tap")
                    self.tearDownTap()
                    self.createTap()
                }
            }
        }
        if let t = healthTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func tearDownTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); eventTap = nil }
        if let src = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            tapSource = nil
        }
        tapUserInfo?.release()
        tapUserInfo = nil
    }

    func unregisterHotkey() {
        healthTimer?.invalidate(); healthTimer = nil
        tearDownTap()
    }

    // MARK: - Show / Hide

    private var didRetainMusicPolling = false

    func show(goBack: Bool = false) {
        // Already visible — ⌘⇥ cycles to the next app instead of reopening
        if state.isVisible {
            state.selectNext()
            return
        }

        if !didRetainMusicPolling {
            didRetainMusicPolling = true
            state.musicMonitor?.retainPolling()
        }

        state.refresh()
        state.resetSearch()
        state.defaultSelection(goBack: goBack)

        if panel == nil { buildPanel() }
        guard let p = panel else { return }

        centerOnCursorScreen(p)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        state.isVisible = true
    }

    func hide(activate: Bool = false) {
        guard state.isVisible else { return }
        if didRetainMusicPolling {
            didRetainMusicPolling = false
            state.musicMonitor?.releasePolling()
        }
        state.isVisible = false
        if let m = cmdMonitor { NSEvent.removeMonitor(m); cmdMonitor = nil }
        if activate { state.activateSelection() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.state.resetSearch()
        })
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let initialRect = NSRect(x: 0, y: 0, width: 940, height: panelHeight)

        let h = NSHostingController<TrayHUDView>(rootView: TrayHUDView(state: state))
        h.view.wantsLayer = true
        h.view.translatesAutoresizingMaskIntoConstraints = false
        hosting = h

        let effect = NSVisualEffectView(frame: initialRect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage.mask(withCornerRadius: 22)
        effect.autoresizingMask = [.width, .height]
        effect.addSubview(h.view)

        NSLayoutConstraint.activate([
            h.view.topAnchor.constraint(equalTo: effect.topAnchor),
            h.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            h.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        let stroke = CALayer()
        stroke.borderColor = NSColor.separatorColor.cgColor
        stroke.borderWidth = 1
        stroke.cornerRadius = 22
        stroke.frame = effect.bounds
        stroke.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        effect.layer?.addSublayer(stroke)

        let p = KeyPanel(contentRect: initialRect,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.contentView = effect
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard self?.state.isVisible == true else { return }
            self?.hide(activate: false)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard self?.state.isVisible == true else { return e }
            if e.keyCode == 53 {
                self?.hide(activate: false)
                return nil
            }
            if e.keyCode == 12 { // Q — quit selected app
                self?.state.quitSelection()
                return nil
            }
            return e
        }

        panel = p
        state.dismissAction = { [weak self] in self?.hide(activate: false) }
    }

    private func centerOnCursorScreen(_ p: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame
        let pw = min(940, sf.width - 40)
        let ph = min(panelHeight, sf.height - 80)
        let ox = sf.minX + (sf.width - pw) / 2
        let oy = sf.minY + (sf.height - ph) / 2
        p.setFrame(NSRect(x: ox, y: oy, width: pw, height: ph), display: true)
    }

    private var panelHeight: CGFloat {
        // tile = size(72); column width ≈ 84+14 spacing = 98
        let tileH: CGFloat = 72
        let rowSpacing: CGFloat = 10
        let cols = max(1, Int((940 - 280 - 40) / 98))
        let activeRows = state.filteredActive.isEmpty ? 0
            : max(1, Int(ceil(Double(state.filteredActive.count) / Double(cols))))
        let hiddenRows = state.filteredHidden.isEmpty ? 0
            : max(1, Int(ceil(Double(state.filteredHidden.count) / Double(cols))))
        let pinnedRows = state.filteredPinned.isEmpty ? 0
            : max(1, Int(ceil(Double(state.filteredPinned.count) / Double(cols))))

        let topPad: CGFloat    = 20
        let searchH: CGFloat   = 36
        let gap: CGFloat       = 10
        let headerH: CGFloat   = 20
        let dividerH: CGFloat  = 25   // rect(1) + vertical padding(2×2) + gap(10) + header(20) - gap
        let bottomPad: CGFloat = 20

        func sectionH(_ rows: Int) -> CGFloat {
            CGFloat(rows) * tileH + CGFloat(max(0, rows - 1)) * rowSpacing
        }

        var h = topPad + searchH + gap + headerH + gap + sectionH(activeRows)
        if hiddenRows > 0 {
            h += dividerH + gap + sectionH(hiddenRows)
        }
        if pinnedRows > 0 {
            h += dividerH + gap + sectionH(pinnedRows)
        }
        h += bottomPad
        return min(max(h, 440), 700)
    }
}

// NSPanel subclass: receives key events without activating the app
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Resizable mask image

fileprivate extension NSImage {
    static func mask(withCornerRadius radius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * radius + 1.0
        let maskImage = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.set()
            bezierPath.fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        maskImage.resizingMode = .stretch
        return maskImage
    }
}
