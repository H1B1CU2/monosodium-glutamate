import AppKit
import QuartzCore

// MARK: - Clean Keyboard

/// Locks the whole keyboard so the keys can be wiped: letters, modifiers,
/// function keys and the media/brightness/volume keys all do nothing. The one
/// way out is holding esc for two seconds (or the HUD's Unlock button). The
/// tap sits at the HID level, ahead of every other tap in the system.
final class KeyboardCleaner {
    static let shared = KeyboardCleaner()

    private(set) var isLocked = false

    /// How long esc must be held.
    private static let holdDuration: TimeInterval = 2.0
    /// The keyboard never stays dead for longer than this.
    private static let maxLockDuration: TimeInterval = 300
    private static let escKeyCode: Int64 = 53
    /// Modifiers whose release is still let through (see `handle`).
    private static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate,
                                                     .maskCommand, .maskSecondaryFn]

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hud: KeyboardCleanerHUD?
    private var holdTimer: Timer?
    private var safetyTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var escHeld = false
    /// Keys already down when the lock began: their release is passed on, so
    /// no app is left thinking one is still held.
    private var heldAtStart: Set<Int64> = []

    private init() {}

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard !isLocked else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyboardCleaner>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        let keyMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        // Raw 14: NX_SYSDEFINED, where brightness, volume and media keys arrive.
        let mask = keyMask | (CGEventMask(1) << 14)
        // No Accessibility permission, no tap: better not to lock than to lock blind.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        heldAtStart = Set((0..<128).filter { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }.map(Int64.init))
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        isLocked = true
        escHeld = false

        let endsAt = Date().addingTimeInterval(Self.maxLockDuration)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let left = Int(endsAt.timeIntervalSinceNow.rounded(.up))
            self?.hud?.setRemaining(left)
            if left <= 0 { self?.stop() }
        }
        // Sleeping or locking the screen ends it: a locked keyboard must never
        // meet the password field.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                              NSWorkspace.sessionDidResignActiveNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }

        Self.play(Self.lockSound)
        let hud = KeyboardCleanerHUD()
        hud.onUnlock = { [weak self] in self?.stop() }
        self.hud = hud
        hud.setRemaining(Int(Self.maxLockDuration))
        hud.show()
    }

    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.stop() }; return }
        end(completed: false)
    }

    /// The padlock sounds the lock screen plays, for locking and unlocking.
    private static let lockSound = NSSound(
        contentsOfFile: "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/lock.aif",
        byReference: true)
    private static let unlockSound = NSSound(
        contentsOfFile: "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/unlock.aif",
        byReference: true)

    private static func play(_ sound: NSSound?) {
        sound?.stop()
        sound?.play()
    }

    private func end(completed: Bool) {
        guard isLocked else { return }
        isLocked = false
        Self.play(Self.unlockSound)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        holdTimer?.invalidate()
        holdTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers = []
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        escHeld = false
        heldAtStart = []
        let closing = hud
        hud = nil
        closing?.dismiss(pulse: completed)
    }

    /// True to swallow the event. Runs on the main run loop.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isLocked, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard isLocked else { return false }
        switch type {
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.escKeyCode {
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { escPressed() }
                } else {
                    escReleased()
                }
                return true
            }
            if type == .keyUp, heldAtStart.remove(code) != nil { return false }
            return true
        case .flagsChanged:
            // Letting go of the last modifier passes, so a modifier held when the
            // lock began (the strip's trigger) isn't left stuck down.
            return !event.flags.intersection(Self.modifierMask).isEmpty
        default:
            return true
        }
    }

    private func escPressed() {
        guard !escHeld else { return }
        escHeld = true
        hud?.holdBegan(duration: Self.holdDuration)
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            self?.end(completed: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func escReleased() {
        guard escHeld else { return }
        escHeld = false
        holdTimer?.invalidate()
        holdTimer = nil
        hud?.holdCancelled()
    }
}

// MARK: - HUD

/// The "Keyboard Locked" card: a progress ring that fills while esc is held.
private final class KeyboardCleanerHUD: NSObject {
    var onUnlock: (() -> Void)?

    private static let size = NSSize(width: 260, height: 244)
    private static let ringSize: CGFloat = 72

    private let panel: NSPanel
    private let root: NSView
    private let ringContainer = CALayer()
    private let ringFill = CAShapeLayer()
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init() {
        let size = Self.size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        root = NSView(frame: NSRect(origin: .zero, size: size))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = root
        root.wantsLayer = true

        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.maskImage = Self.roundedMask(radius: 22)
        root.addSubview(effect)

        // Top to bottom: ring 28–100, title, subtitle, Unlock.
        let ring = NSView(frame: NSRect(x: (size.width - Self.ringSize) / 2, y: 144,
                                        width: Self.ringSize, height: Self.ringSize))
        ring.wantsLayer = true
        buildRing(in: ring)
        effect.addSubview(ring)

        let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
        let icon = NSImageView(image: symbol ?? NSImage())
        icon.contentTintColor = .white
        icon.imageAlignment = .alignCenter
        icon.frame = ring.frame
        effect.addSubview(icon)

        let title = NSTextField(labelWithString: "Keyboard Locked")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 20, y: 116, width: size.width - 40, height: 20)
        effect.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Clean away. Hold esc for 2 seconds to unlock.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor(white: 1, alpha: 0.6)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.frame = NSRect(x: 30, y: 80, width: size.width - 60, height: 30)
        effect.addSubview(subtitle)

        // How long until it unlocks by itself.
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countdown.textColor = NSColor(white: 1, alpha: 0.45)
        countdown.alignment = .center
        countdown.frame = NSRect(x: 20, y: 54, width: size.width - 40, height: 16)
        effect.addSubview(countdown)

        let button = NSButton(frame: NSRect(x: (size.width - 64) / 2, y: 20, width: 64, height: 22))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        button.attributedTitle = NSAttributedString(string: "Unlock", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
            .paragraphStyle: style,
        ])
        button.target = self
        button.action = #selector(unlockClicked)
        effect.addSubview(button)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// A circle from 12 o'clock, clockwise, as a track and a fill on top.
    private func buildRing(in view: NSView) {
        let side = Self.ringSize
        let radius = (side - 4) / 2
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ringContainer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        for (layer, color) in [(CAShapeLayer(), NSColor(white: 1, alpha: 0.18)), (ringFill, NSColor(white: 1, alpha: 0.95))] {
            layer.frame = ringContainer.bounds
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 4
            layer.lineCap = .round
            ringContainer.addSublayer(layer)
        }
        ringFill.strokeEnd = 0
        view.layer?.addSublayer(ringContainer)
    }

    @objc private func unlockClicked() { onUnlock?() }

    private let countdown = NSTextField(labelWithString: "")

    func setRemaining(_ seconds: Int) {
        let s = max(0, seconds)
        countdown.stringValue = String(format: "Unlocks by itself in %d:%02d", s / 60, s % 60)
    }

    // MARK: Show / hide

    func show() {
        let screen = NSScreen.screens.first(where: \.isBuiltin) ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = root.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: centeredScale(0.94, in: layer))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 17
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    /// Scale about the middle whatever the layer's anchor point is.
    private func centeredScale(_ scale: CGFloat, in layer: CALayer) -> CATransform3D {
        let tx = (1 - scale) * (layer.bounds.midX - layer.anchorPoint.x * layer.bounds.width)
        let ty = (1 - scale) * (layer.bounds.midY - layer.anchorPoint.y * layer.bounds.height)
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(tx, ty, 0))
    }

    /// `pulse`: the hold completed, so the ring flashes once before the fade.
    func dismiss(pulse: Bool) {
        if pulse && !reduceMotion {
            let flash = CAKeyframeAnimation(keyPath: "transform.scale")
            flash.values = [1, 1.14, 1]
            flash.keyTimes = [0, 0.4, 1]
            flash.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            flash.duration = 0.25
            ringContainer.add(flash, forKey: "pulse")
        }
        let panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + (pulse ? 0.15 : 0)) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    // MARK: Ring

    private var ringValue: Float { Float(ringFill.presentation()?.strokeEnd ?? ringFill.strokeEnd) }

    /// Esc went down: fill from where the ring is to full over the hold.
    func holdBegan(duration: TimeInterval) {
        animateRing(to: 1, duration: duration, timing: CAMediaTimingFunction(name: .linear))
    }

    /// Esc came up early: back to empty.
    func holdCancelled() {
        animateRing(to: 0, duration: 0.25, timing: CAMediaTimingFunction(name: .easeOut))
    }

    private func animateRing(to value: Float, duration: TimeInterval, timing: CAMediaTimingFunction) {
        let from = ringValue
        ringFill.removeAnimation(forKey: "progress")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringFill.strokeEnd = CGFloat(value)
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        ringFill.add(animation, forKey: "progress")
    }
}
