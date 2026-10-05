import AppKit
import LocalAuthentication
import QuartzCore

// MARK: - SkyLight lock-screen space

// A window can only be drawn over the lock screen from a SkyLight space whose
// absolute level sits above it. These are private; every symbol is resolved at
// runtime so a macOS that drops one disables the feature instead of the app.
/// A SkyLight space of its own at an absolute level: windows in it sit
/// above every ordinary Space and stay put while those switch.
enum SkyLightSpace {
    /// Above the lock screen (300), alongside Notification Center's lock-screen layer.
    static let lockScreenLevel: Int32 = 400

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias HideSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let spaceCreate = symbol("SLSSpaceCreate", as: SpaceCreate.self)
    private static let setAbsoluteLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SetAbsoluteLevel.self)
    private static let showSpaces = symbol("SLSShowSpaces", as: ShowSpaces.self)
    private static let hideSpaces = symbol("SLSHideSpaces", as: HideSpaces.self)
    private static let addWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self)
    private static let spaceDestroy = symbol("SLSSpaceDestroy", as: SpaceDestroy.self)

    static var isAvailable: Bool {
        mainConnection != nil && spaceCreate != nil && setAbsoluteLevel != nil &&
            showSpaces != nil && hideSpaces != nil && addWindows != nil && spaceDestroy != nil
    }

    /// Creates a shown space at `level` holding `window`.
    static func present(_ window: NSWindow, level: Int32 = lockScreenLevel) -> UInt64? {
        guard isAvailable, let cid = mainConnection?() else { return nil }
        guard let space = spaceCreate?(cid, 1, 0), space != 0 else { return nil }
        _ = setAbsoluteLevel?(cid, space, level)
        _ = showSpaces?(cid, [NSNumber(value: space)] as CFArray)
        // 7: remove the window from every Space it was on.
        _ = addWindows?(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return space
    }

    static func setLevel(_ space: UInt64, _ level: Int32) {
        guard let cid = mainConnection?() else { return }
        _ = setAbsoluteLevel?(cid, space, level)
    }

    static func setShown(_ space: UInt64, _ shown: Bool) {
        guard let cid = mainConnection?() else { return }
        _ = (shown ? showSpaces : hideSpaces)?(cid, [NSNumber(value: space)] as CFArray)
    }

    static func dismiss(_ space: UInt64) {
        guard let cid = mainConnection?() else { return }
        _ = hideSpaces?(cid, [NSNumber(value: space)] as CFArray)
        _ = spaceDestroy?(cid, space)
    }
}

// MARK: - Controller

/// Points at the Touch ID key from the lock screen and whenever an app asks
/// for Touch ID, and plays a confirmation when the Mac unlocks or the prompt
/// is answered with a finger.
///
/// macOS reports no finger-on-sensor event to apps — only the unlock itself —
/// so the "scanned" animation plays on unlock (a Touch ID or password unlock).
final class LockScreenTouchIDController {
    static let shared = LockScreenTouchIDController()

    private var window: NSWindow?
    private var hintView: TouchIDHintView?
    private var space: UInt64?
    private var started = false
    /// The hint currently up is for an app's Touch ID prompt, not the lock screen.
    private var showingForPrompt = false

    private var teardownWork: DispatchWorkItem?

    private static let enabledKey = "lockScreenTouchIDHint"
    /// Horizontal position of the Touch ID key under the built-in display, as a
    /// fraction of its width (the key is the top-right key of the keyboard).
    private static let keyPositionKey = "lockScreenTouchIDKeyX"

    private static let unlockSoundKey = "lockScreenUnlockSound"
    private static let lockSoundKey = "lockScreenLockSound"

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var playsUnlockSound: Bool {
        UserDefaults.standard.object(forKey: Self.unlockSoundKey) as? Bool ?? true
    }

    private var playsLockSound: Bool {
        UserDefaults.standard.object(forKey: Self.lockSoundKey) as? Bool ?? true
    }

    /// macOS's own padlock-closing sound, the pair to `unlockSound`.
    private lazy var lockSound: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/lock.aif",
        byReference: true)

    /// macOS's own padlock-opening sound (System Settings' lock button).
    private lazy var unlockSound: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Frameworks/SecurityInterface.framework/Versions/A/Resources/unlock.aif",
        byReference: true)

    private var usabilityTimer: Timer?
    private var sampleTimer: Timer?
    /// A live unlock observed by this process is the only reliable evidence
    /// that the current login session has passed macOS's password gate.
    private var lastObservedUnlockAt: Date?
    private static let unlockEvidenceLifetime: TimeInterval = 47 * 60 * 60

    private func hasRecentUnlockEvidence(at now: Date = Date()) -> Bool {
        guard let lastObservedUnlockAt else { return false }
        let age = now.timeIntervalSince(lastObservedUnlockAt)
        return age >= 0 && age < Self.unlockEvidenceLifetime
    }

    /// Touch ID has fingers enrolled and isn't locked out after failed scans.
    private func touchIDAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok && context.biometryType == .touchID
    }

    /// "Use Touch ID to unlock your Mac" — off or unreadable means we must
    /// not suggest a finger can unlock the screen.
    private func touchIDUnlocksMac() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/bioutil")
        task.arguments = ["-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.split(separator: "\n")
            .first(where: { $0.contains("Effective biometrics for unlock") }) else { return false }
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
    }

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.lastObservedUnlockAt = nil
                self?.teardownWork?.cancel()
                self?.teardown()
            }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenUnlocked() }
        // Preview without locking: plays the hint over the desktop, then the
        // unlock, e.g. `notifyutil`-style from a script or the terminal.
        dnc.addObserver(forName: Notification.Name("H1D3S1GN.MSG.previewTouchIDHint"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked(preview: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self?.screenUnlocked(observedSystemUnlock: false)
            }
        }
        // The prompt's window, from SystemState's window-list pass. Its agent's
        // activation isn't usable: for many prompts it only activates as the
        // sheet closes, which showed the hint a moment after it was gone.
        NotificationCenter.default.addObserver(forName: SystemState.touchIDPromptChanged,
                                               object: nil, queue: .main) { [weak self] note in
            if note.userInfo?["visible"] as? Bool == true {
                self?.promptShown()
            } else {
                self?.promptClosed()
            }
        }
    }

    // MARK: App Touch ID prompts

    /// A prompt is up that played the lock sound, so its close by finger
    /// gets the unlock sound — the lock screen's pair, on or off the strip.
    private var promptSounded = false

    private func promptShown() {
        // The lock screen's own hint (or a prompt already shown) stays as is.
        guard hintView == nil, isEnabled, PresentationState.shared.canPresent,
              touchIDAvailable() else { return }
        if !promptSounded {
            promptSounded = true
            if playsLockSound, let lockSound {
                lockSound.stop()
                lockSound.play()
            }
        }
        // The Edge Keys strip's Touch ID key turns into the fingerprint itself.
        // (Left off the strip, the key comes back for the prompt.)
        guard !EdgeKeyStrip.shared.isVisible else { return }
        guard presentHint(onLockScreen: false) else { return }
        showingForPrompt = true
    }

    /// No outcome is published, so read it from the input: Cancel, Esc and a
    /// typed password all end with a click or a key; a finger on the sensor
    /// produces neither. A finger gets the unlock animation, the rest a fade.
    private func promptClosed() {
        func sinceLast(_ type: CGEventType) -> TimeInterval {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
        }
        let answeredByInput = min(sinceLast(.leftMouseDown), sinceLast(.keyDown)) < 0.5
        if promptSounded {
            promptSounded = false
            if !answeredByInput, playsUnlockSound, let unlockSound {
                unlockSound.stop()
                unlockSound.play()
            }
        }
        guard showingForPrompt, let view = hintView else { return }
        showingForPrompt = false
        if answeredByInput { view.playHidden() } else { view.playUnlocked() }
        scheduleTeardown()
    }

    private func scheduleTeardown() {
        teardownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.teardown() }
        teardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchIDHintView.unlockDuration, execute: work)
    }

    private func screenLocked(preview: Bool = false) {
        if playsLockSound, let lockSound {
            lockSound.stop()
            lockSound.play()
        }
        // A lock notification can arrive while an app-authentication hint is
        // still up. Never leave that hint over a password-only lock screen.
        teardownWork?.cancel()
        teardown()
        promptSounded = false

        // LocalAuthentication reports whether app biometrics are available,
        // not whether Touch ID can unlock this particular lock screen. Fail
        // closed until we have seen a real unlock in this process, then expire
        // that evidence before macOS's 48-hour password requirement.
        guard isEnabled, SkyLightSpace.isAvailable,
              (preview || hasRecentUnlockEvidence()),
              touchIDAvailable(), touchIDUnlocksMac() else { return }
        // A prompt's hint moves onto the lock screen with a fresh window.
        showingForPrompt = false
        guard presentHint(onLockScreen: true) else { return }

        // A failed-scan lockout or expired unlock evidence can happen while
        // the screen is still locked; remove the hint as soon as detected.
        usabilityTimer?.invalidate()
        usabilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let view = self.hintView,
                  !preview && (!self.hasRecentUnlockEvidence() || !self.touchIDAvailable()) else { return }
            self.usabilityTimer?.invalidate()
            view.playHidden()
            self.scheduleTeardown()
        }
    }

    /// Shows the hint on the built-in display — the Touch ID key is on its
    /// keyboard, whichever display a prompt opened on. On the lock screen it
    /// goes into a SkyLight space above it; otherwise a screen-saver-level
    /// window already sits above the prompt's sheet. False when there's no
    /// built-in display (lid closed) or the lock-screen space can't be made.
    @discardableResult
    private func presentHint(onLockScreen: Bool) -> Bool {
        guard let screen = NSScreen.screens.first(where: \.isBuiltin) else { return false }
        teardownWork?.cancel()
        teardown()

        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: false)

        let keyX = UserDefaults.standard.object(forKey: Self.keyPositionKey) as? Double ?? Double(FunctionRow.touchID)
        let view = TouchIDHintView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                   keyX: CGFloat(keyX))
        window.contentView = view
        window.orderFrontRegardless()

        if onLockScreen {
            guard let space = SkyLightSpace.present(window) else {
                window.orderOut(nil)
                return false
            }
            self.space = space
        } else if EdgeKeyStrip.shared.isVisible,
                  let space = SkyLightSpace.present(window, level: EdgeKeyStrip.spaceLevel + 1) {
            // The Edge Keys strip sits in a space above ordinary windows;
            // the hint has to be above it to be seen.
            self.space = space
        } else {
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        self.window = window
        self.hintView = view
        adaptToBackdrop(animated: false)
        view.playHint()
        // What's behind can change while it's up; a few-pixel sample is cheap.
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.adaptToBackdrop(animated: true)
        }
        return true
    }

    /// White on dark shading or dark on light frosting, from the brightness
    /// of what's behind the hint — see `EdgeHUDStyle`.
    private func adaptToBackdrop(animated: Bool) {
        guard let window, let view = hintView else { return }
        let rect = view.scrimRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        guard let luminance = BackdropLuminance.sample(appKitRect: rect,
                                                       below: CGWindowID(window.windowNumber)) else { return }
        let style = EdgeHUDStyle.next(for: luminance, from: view.style)
        if style != view.style || !animated { view.apply(style, animated: animated) }
    }

    private func screenUnlocked(observedSystemUnlock: Bool = true) {
        if observedSystemUnlock { lastObservedUnlockAt = Date() }
        if playsUnlockSound, let unlockSound {
            unlockSound.stop()
            unlockSound.play()
        }
        guard let view = hintView, !showingForPrompt else { return }
        view.playUnlocked()
        scheduleTeardown()
    }

    private func teardown() {
        showingForPrompt = false
        usabilityTimer?.invalidate()
        usabilityTimer = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        if let space { SkyLightSpace.dismiss(space) }
        window?.orderOut(nil)
        window = nil
        hintView = nil
        space = nil
    }
}

// MARK: - View

/// iPad-style: a short bar on the screen edge right above the Touch ID key,
/// labelled "Touch ID", the way iPadOS marks its top-button sensor.
final class TouchIDHintView: NSView {
    /// Time from unlock to teardown; the unlock is meant to feel instant.
    static let unlockDuration: TimeInterval = 0.2

    private let keyX: CGFloat
    private let bar = CALayer()
    private let label = CATextLayer()
    /// Dim-and-blur scrim rising from the edge behind the hint, feathered to
    /// nothing so there's no panel edge. iPadOS keeps this hint readable over
    /// live apps because its confirmation sheet dims the whole screen; the
    /// macOS Touch ID sheet dims nothing, so the hint brings its own dimming,
    /// only where it sits.
    private let scrim = TouchIDHintScrim()
    private let content = NSView()
    private(set) var style: EdgeHUDStyle = .dark(luminance: 0.5)
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let text = "Touch ID"
    var scrimRect: CGRect { scrim.frame }
    /// Just the label and bar plus a feathered margin — wider reached into
    /// whatever sat above the key (a chat box's text) for no reason.
    private static let scrimSize = CGSize(width: 210, height: 60)

    /// Flush on the display's edge, like iPadOS's top-button mark: square
    /// where it meets the edge, rounded on the inner side.
    static let barSize = CGSize(width: 74, height: 3.5)
    private static let barInset: CGFloat = 0

    init(frame: CGRect, keyX: CGFloat) {
        self.keyX = min(0.98, max(0.02, keyX))
        super.init(frame: frame)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let x = bounds.width * keyX

        scrim.frame = CGRect(x: (x - Self.scrimSize.width / 2).rounded(), y: 0,
                             width: Self.scrimSize.width, height: Self.scrimSize.height)
        scrim.alphaValue = 0
        addSubview(scrim)

        content.frame = bounds
        content.wantsLayer = true
        addSubview(content)
        // A soft glow around the white glyphs on top, as the lock screen's
        // clock and notifications have.
        guard let root = content.layer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        bar.bounds = CGRect(origin: .zero, size: Self.barSize)
        bar.position = CGPoint(x: x, y: Self.barInset + Self.barSize.height / 2)
        bar.cornerRadius = 3
        bar.cornerCurve = .continuous
        bar.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        bar.backgroundColor = NSColor.white.cgColor
        bar.shadowColor = NSColor.black.cgColor
        bar.shadowOpacity = 0.45
        bar.shadowRadius = 6
        bar.shadowOffset = .zero
        bar.opacity = 0
        root.addSublayer(bar)

        let width = ceil((Self.text as NSString).size(withAttributes: [.font: Self.font]).width) + 4
        label.string = Self.labelString(color: .white)
        label.alignmentMode = .center
        label.contentsScale = scale
        label.bounds = CGRect(x: 0, y: 0, width: width, height: 17)
        label.position = CGPoint(x: x, y: Self.barInset + Self.barSize.height + 15)
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.55
        label.shadowRadius = 7
        label.shadowOffset = .zero
        label.opacity = 0
        root.addSublayer(label)
    }

    private func fadeScrim(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrim.animator().alphaValue = alpha
        }
    }

    private static func labelString(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// White on dark shading, or dark on light frosting — see `EdgeHUDStyle`.
    func apply(_ style: EdgeHUDStyle, animated: Bool) {
        let recolor = style.isLight != self.style.isLight || !animated
        self.style = style
        scrim.apply(style, animated: animated)
        guard recolor else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        bar.backgroundColor = style.glyph.cgColor
        bar.shadowColor = style.glow.cgColor
        // Half the key HUDs' glow: a full one bloomed into a bright patch
        // over the lock screen's light wallpaper.
        bar.shadowOpacity = style.glowOpacity * 0.45
        label.string = Self.labelString(color: style.glyph)
        label.shadowColor = style.glow.cgColor
        label.shadowOpacity = style.glowOpacity * 0.5
        CATransaction.commit()
    }

    func playHint() {
        fadeScrim(to: 1, duration: 0.35)
        // The bar draws out from its center, then the label rises in.
        let grow = CASpringAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 4
        grow.toValue = Self.barSize.width
        grow.damping = 16
        grow.stiffness = 220
        grow.duration = grow.settlingDuration
        bar.add(grow, forKey: "grow")
        bar.opacity = 1

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let appear = CAAnimationGroup()
        appear.animations = [rise, fade]
        appear.duration = 0.4
        appear.beginTime = CACurrentMediaTime() + 0.12
        appear.fillMode = .backwards
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        label.add(appear, forKey: "appear")
        label.opacity = 1

        // A slow, faint breath on the bar.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.55
        breathe.duration = 1.4
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.beginTime = CACurrentMediaTime() + 0.6
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(breathe, forKey: "breathe")
    }

    /// Touch ID stopped being an option: the hint quietly fades.
    func playHidden() {
        fadeScrim(to: 0, duration: 0.3)
        for layer in [bar, label] as [CALayer] {
            layer.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.3
            layer.opacity = 0
            layer.add(fade, forKey: "hide")
        }
    }

    /// Instant: the hint is spent — the bar pinches into its center and
    /// the label fades with it, all well inside the lock screen's own exit.
    func playUnlocked() {
        fadeScrim(to: 0, duration: 0.14)
        bar.removeAllAnimations()
        label.removeAllAnimations()

        let labelGroup = CAAnimationGroup()
        let labelShrink = CABasicAnimation(keyPath: "transform.scale")
        labelShrink.fromValue = 1
        labelShrink.toValue = 0.9
        let labelFade = CABasicAnimation(keyPath: "opacity")
        labelFade.fromValue = label.presentation()?.opacity ?? 1
        labelFade.toValue = 0
        labelGroup.animations = [labelShrink, labelFade]
        labelGroup.duration = 0.1
        labelGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
        label.opacity = 0
        label.add(labelGroup, forKey: "leave")

        let barGroup = CAAnimationGroup()
        let pinch = CABasicAnimation(keyPath: "bounds.size.width")
        pinch.fromValue = bar.presentation()?.bounds.width ?? Self.barSize.width
        pinch.toValue = Self.barSize.height
        let barFade = CABasicAnimation(keyPath: "opacity")
        barFade.fromValue = bar.presentation()?.opacity ?? 1
        barFade.toValue = 0
        barGroup.animations = [pinch, barFade]
        barGroup.duration = 0.16
        barGroup.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
        bar.opacity = 0
        bar.add(barGroup, forKey: "leave")
    }
}

// MARK: - Scrim

/// The hint's backing: a light blur of what's behind with a faint tint,
/// feathered from the edge to nothing. Gentler than the key HUDs' scrim,
/// whose frosting read as a hard white patch on the lock screen.
private final class TouchIDHintScrim: NSView {
    private let backdrop: CALayer
    private let tint = CALayer()
    private let feather = CAGradientLayer()
    private static let blurRadius: CGFloat = 7

    override init(frame: NSRect) {
        // CABackdropLayer blurs whatever the window server draws behind
        // the window — the lock screen included. A plain layer (tint only)
        // if it's ever missing.
        if let type = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            backdrop = type.init()
            backdrop.setValue(true, forKey: "windowServerAware")
            if let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
               let blur = filterType.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject {
                blur.setValue(Self.blurRadius, forKey: "inputRadius")
                blur.setValue(true, forKey: "inputNormalizeEdges")
                backdrop.filters = [blur]
            }
        } else {
            backdrop = CALayer()
        }
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.addSublayer(backdrop)
        root.addSublayer(tint)
        feather.type = .radial
        feather.startPoint = CGPoint(x: 0.5, y: 0)
        feather.endPoint = CGPoint(x: 1, y: 1)
        let stops: [(CGFloat, CGFloat)] = [(0, 0.9), (0.3, 0.72), (0.55, 0.42), (0.75, 0.16), (0.9, 0.04), (1, 0)]
        feather.colors = stops.map { NSColor.white.withAlphaComponent($0.1).cgColor }
        feather.locations = stops.map { NSNumber(value: Double($0.0)) }
        root.mask = feather
        alphaValue = 0
        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [backdrop, tint, feather] { layer.frame = bounds }
        CATransaction.commit()
    }

    /// A faint dark shade under white glyphs, a faint light one under dark.
    func apply(_ style: EdgeHUDStyle, animated: Bool) {
        let color: NSColor
        switch style {
        case .light: color = NSColor.white.withAlphaComponent(0.12)
        case .dark(let luminance): color = NSColor.black.withAlphaComponent(0.08 + 0.14 * min(1, luminance / 0.6))
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        tint.backgroundColor = color.cgColor
        CATransaction.commit()
    }
}
