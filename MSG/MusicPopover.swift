import AppKit

final class MusicPopover {
    private let monitor: MusicMonitor
    private let window: NSWindow
    private var closeMonitor: Any?
    private weak var titleLabel: NSTextField?
    private weak var artistLabel: NSTextField?
    private weak var volumeBar: VolumeBar?

    var isShown: Bool { window.isVisible }

    init(monitor: MusicMonitor) {
        self.monitor = monitor

        let w: CGFloat = 208, h: CGFloat = 240
        let (root, title, artist, volBar) = makeRootView(w: w, h: h, monitor: monitor)

        titleLabel = title
        artistLabel = artist
        volumeBar = volBar

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = root
    }

    func show(relativeTo button: NSStatusBarButton) {
        titleLabel?.stringValue = monitor.currentTitle ?? "Not Playing"
        artistLabel?.stringValue = monitor.currentArtist ?? ""
        volumeBar?.setLevel(CGFloat(monitor.volume) / 100.0)

        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.bounds)
        let popX = buttonFrame.midX - window.frame.width / 2
        let popY = buttonFrame.minY - 2
        window.setFrameTopLeftPoint(NSPoint(x: popX, y: popY))
        window.orderFront(nil)

        closeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            DispatchQueue.main.async { self.close() }
        }
    }

    func close() {
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        window.orderOut(nil)
    }
}

// MARK: - Root View Factory

private func makeRootView(w: CGFloat, h: CGFloat, monitor: MusicMonitor) -> (NSView, NSTextField, NSTextField, VolumeBar) {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

    // Popover background
    let bg = NSVisualEffectView(frame: root.bounds)
    bg.material = .fullScreenUI
    bg.blendingMode = .behindWindow
    bg.state = .active
    bg.wantsLayer = true
    bg.layer?.cornerRadius = 30
    bg.layer?.masksToBounds = true
    bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
    bg.layer?.borderWidth = 0.5
    bg.autoresizingMask = [.width, .height]
    root.addSubview(bg)

    // Touch pad
    let padW: CGFloat = 160, padH: CGFloat = 160
    let padX: CGFloat = 12
    let padY: CGFloat = h - padH - 12
    let touchPad = TouchPad(frame: NSRect(x: padX, y: padY, width: padW, height: padH))
    touchPad.wantsLayer = true
    touchPad.layer?.cornerRadius = 20
    touchPad.layer?.masksToBounds = true
    touchPad.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    touchPad.monitor = monitor
    root.addSubview(touchPad)

    // Feedback icon centered in pad
    let icon = NSImageView(frame: .zero)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.contentTintColor = .labelColor
    icon.alphaValue = 0
    icon.wantsLayer = true
    icon.translatesAutoresizingMaskIntoConstraints = false
    touchPad.addSubview(icon)
    touchPad.iconView = icon

    // Volume bar outside pad, to the right
    let barW: CGFloat = 20
    let barH: CGFloat = padH
    let barX: CGFloat = padX + padW + 4
    let barY: CGFloat = padY
    let volBar = VolumeBar(frame: NSRect(x: barX, y: barY, width: barW, height: barH))
    volBar.wantsLayer = true
    root.addSubview(volBar)
    touchPad.volumeBar = volBar
    volBar.setLevel(CGFloat(monitor.volume) / 100.0)

    NSLayoutConstraint.activate([
        icon.centerXAnchor.constraint(equalTo: touchPad.centerXAnchor),
        icon.centerYAnchor.constraint(equalTo: touchPad.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 48),
        icon.heightAnchor.constraint(equalToConstant: 48),
    ])

    // Track title
    let title = NSTextField(labelWithString: "")
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = .labelColor
    title.alignment = .center
    title.lineBreakMode = .byTruncatingTail
    title.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(title)

    // Artist
    let artist = NSTextField(labelWithString: "")
    artist.font = .systemFont(ofSize: 11)
    artist.textColor = .secondaryLabelColor
    artist.alignment = .center
    artist.lineBreakMode = .byTruncatingTail
    artist.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(artist)

    NSLayoutConstraint.activate([
        title.topAnchor.constraint(equalTo: touchPad.bottomAnchor, constant: 10),
        title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
        title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        artist.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        artist.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
        artist.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
    ])

    return (root, title, artist, volBar)
}

// MARK: - VolumeBar

private final class VolumeBar: NSView {
    private var level: CGFloat = 0.5

    func setLevel(_ value: CGFloat) {
        level = max(0, min(1, value))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackWidth: CGFloat = 6
        let inset: CGFloat = 4

        let trackX = (bounds.width - trackWidth) / 2
        let usableHeight = bounds.height - 2 * inset
        let trackRect = NSRect(x: trackX, y: inset, width: trackWidth, height: usableHeight)
        let trackRadius = trackWidth / 2

        // Track background
        let trackBg = NSColor.white.withAlphaComponent(0.08)
        trackBg.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: trackRadius, yRadius: trackRadius).fill()

        // Fill as pill shape rising from bottom
        let fillH = usableHeight * level
        if fillH > trackRadius {
            let fillRect = NSRect(x: trackX, y: inset, width: trackWidth, height: fillH)
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: trackRadius, yRadius: trackRadius).fill()
        } else if fillH > 0 {
            let r = fillH / 2
            let fillRect = NSRect(x: trackX, y: inset, width: trackWidth, height: fillH)
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()
        }

        // Indicator dots — match touch pad grid spacing
        let dotColor = NSColor.white.withAlphaComponent(0.25)
        dotColor.setFill()
        let dotR: CGFloat = 1.0
        let dotCenterX = trackX + trackWidth + 7
        let padInset: CGFloat = 24
        let rows = 8
        let rowSpacing = (bounds.height - 2 * padInset) / CGFloat(rows - 1)
        for row in 1..<(rows - 1) {
            let dotY = padInset + CGFloat(row) * rowSpacing
            let dotRect = NSRect(x: dotCenterX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}

// MARK: - TouchPad

private final class TouchPad: NSView {
    var monitor: MusicMonitor?
    var iconView: NSImageView?
    var volumeBar: VolumeBar?

    private var feedbackTimer: Timer?
    private var lastHorizontalDirection: CGFloat = 0

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var skipFired = false
    private var thresholdHapticFired = false
    private var volumeRemainder: CGFloat = 0
    private var peakVelocity: CGFloat = 0

    private let lockThreshold: CGFloat = 8
    private let skipThreshold: CGFloat = 60
    private let deadZone: CGFloat = 20
    private let volumeStep: CGFloat = 15

    override var acceptsTouchEvents: Bool { get { true } set {} }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let dotR: CGFloat = 1.0
        let cols = 7, rows = 8
        let padInset: CGFloat = 24
        let colSpacing = (bounds.width - 2 * padInset) / CGFloat(cols - 1)
        let rowSpacing = (bounds.height - 2 * padInset) / CGFloat(rows - 1)

        let dotColor = NSColor.white.withAlphaComponent(0.06)
        dotColor.setFill()

        for row in 0..<rows {
            for col in 0..<cols {
                let x = padInset + CGFloat(col) * colSpacing
                let y = padInset + CGFloat(row) * rowSpacing
                let dotRect = NSRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    // MARK: Tap

    override func mouseUp(with event: NSEvent) {
        monitor?.togglePlayPause()
        flashIcon("playpause.fill")
        haptic(.generic)
    }

    // MARK: Swipe

    override func scrollWheel(with event: NSEvent) {
        guard event.phase != [] else { return }

        if event.phase == .began {
            accumX = 0; accumY = 0
            axis = .undecided
            skipFired = false
            thresholdHapticFired = false
            peakVelocity = 0
            volumeRemainder = 0
            volumeBar?.setLevel(CGFloat(monitor?.volume ?? 50) / 100.0)
        }

        let prevAccumX = accumX
        accumX += event.scrollingDeltaX
        accumY += event.scrollingDeltaY
        peakVelocity = max(peakVelocity, abs(event.scrollingDeltaX))

        // Reset haptic when reversing past neutral so it re-fires in the new direction
        if (prevAccumX < 0 && accumX >= 0) || (prevAccumX > 0 && accumX <= 0) {
            thresholdHapticFired = false
            peakVelocity = 0
        }

        if axis == .undecided {
            if abs(accumX) > lockThreshold || abs(accumY) > lockThreshold {
                axis = abs(accumX) > abs(accumY) ? .horizontal : .vertical
            }
        }

        switch axis {
        case .undecided:
            break

        case .horizontal:
            if abs(accumX) < deadZone {
                hideIcon()
            } else {
                let active = abs(accumX) - deadZone
                let activeRange = skipThreshold - deadZone
                let progress = min(1.0, active / activeRange)
                let name = accumX > 0 ? "backward.fill" : "forward.fill"
                showHint(name, progress: progress)
            }

            if !thresholdHapticFired {
                let velocityFactor = min(2.0, max(0.5, peakVelocity / 15))
                let effectiveThreshold = deadZone + skipThreshold / velocityFactor
                if abs(accumX) >= effectiveThreshold {
                    haptic(.generic)
                    thresholdHapticFired = true
                }
            }

        case .vertical:
            volumeRemainder -= event.scrollingDeltaY
            if abs(volumeRemainder) >= volumeStep {
                let steps = Int(volumeRemainder / volumeStep)
                monitor?.adjustVolume(by: steps * 2)
                volumeRemainder -= CGFloat(steps) * volumeStep
                haptic(.levelChange)
            }
            volumeBar?.setLevel(CGFloat(monitor?.volume ?? 50) / 100.0)
            showVolumeHint()
        }

        if event.phase == .ended || event.phase == .cancelled {
            if axis == .horizontal {
                let velocityFactor = min(2.0, max(0.5, peakVelocity / 15))
                let effectiveThreshold = deadZone + skipThreshold / velocityFactor
                if abs(accumX) >= effectiveThreshold {
                    let name = accumX > 0 ? "backward.fill" : "forward.fill"
                    if accumX > 0 { monitor?.previousTrack() }
                    else { monitor?.nextTrack() }
                    flashIcon(name)
                    skipFired = true
                    haptic(.alignment)
                }
            }
            if axis == .horizontal && !skipFired { dismissIcon() }
            if axis == .vertical { fadeOutIcon() }
            axis = .undecided
        }
    }

    // MARK: Feedback

    private func hideIcon() {
        guard let icon = iconView, icon.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            icon.animator().alphaValue = 0
        }
    }

    private func showVolumeHint() {
        guard let icon = iconView else { return }
        feedbackTimer?.invalidate()
        let vol = monitor?.volume ?? 50
        let name: String
        switch vol {
        case 0:  name = "speaker.slash.fill"
        case 1...33: name = "speaker.fill"
        case 34...66: name = "speaker.wave.1.fill"
        default: name = "speaker.wave.2.fill"
        }
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon.alphaValue = 0.15
        icon.layer?.setAffineTransform(.identity)
    }

    private func showHint(_ name: String, progress: CGFloat) {
        guard let icon = iconView else { return }
        feedbackTimer?.invalidate()
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)

        let direction = accumX > 0 ? CGFloat(1) : CGFloat(-1)
        lastHorizontalDirection = direction

        let slideOffset: CGFloat = 50 * (1 - progress) * -direction
        icon.alphaValue = 0.08 + progress * 0.25
        icon.layer?.setAffineTransform(CGAffineTransform(translationX: slideOffset, y: 0))
    }

    private func flashIcon(_ name: String) {
        guard let icon = iconView else { return }
        feedbackTimer?.invalidate()
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)

        let direction = lastHorizontalDirection
        let popOffset: CGFloat = 15 * -direction
        icon.alphaValue = 0.6
        icon.layer?.setAffineTransform(CGAffineTransform(translationX: popOffset, y: 0))

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            icon.animator().alphaValue = 1
            icon.animator().layer?.setAffineTransform(.identity)
        }

        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.fadeOutIcon()
        }
        if let t = feedbackTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func fadeOutIcon() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            iconView?.animator().alphaValue = 0
        }
    }

    private func dismissIcon() {
        let direction = lastHorizontalDirection
        let exitOffset: CGFloat = 35 * -direction
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            iconView?.animator().alphaValue = 0
            iconView?.animator().layer?.setAffineTransform(
                CGAffineTransform(translationX: exitOffset, y: 0))
        }
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
