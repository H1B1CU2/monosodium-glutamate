import AppKit
import LocalAuthentication
import QuartzCore

// MARK: - SkyLight lock-screen space

// A window can only be drawn over the lock screen from a SkyLight space whose
// absolute level sits above it. These are private; every symbol is resolved at
// runtime so a macOS that drops one disables the feature instead of the app.
private enum LockScreenSpace {
    /// Above the lock screen (300), alongside Notification Center's lock-screen layer.
    static let absoluteLevel: Int32 = 400

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

    /// Creates a shown space above the lock screen holding `window`.
    static func present(_ window: NSWindow) -> UInt64? {
        guard isAvailable, let cid = mainConnection?() else { return nil }
        guard let space = spaceCreate?(cid, 1, 0), space != 0 else { return nil }
        _ = setAbsoluteLevel?(cid, space, absoluteLevel)
        _ = showSpaces?(cid, [NSNumber(value: space)] as CFArray)
        // 7: remove the window from every Space it was on.
        _ = addWindows?(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return space
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

    /// Touch ID has fingers enrolled and isn't locked out after failed scans.
    private func touchIDAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ok && context.biometryType == .touchID
    }

    /// Only the lockout after failed scans — not any other answer, since what
    /// LocalAuthentication reports while the screen is locked is unverified.
    private func touchIDLockedOut() -> Bool {
        var error: NSError?
        _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return error?.code == LAError.biometryLockout.rawValue
    }

    /// "Use Touch ID to unlock your Mac" — off means the lock screen wants a
    /// password however many fingers are enrolled. Unknown counts as on.
    private func touchIDUnlocksMac() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/bioutil")
        task.arguments = ["-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return true }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.split(separator: "\n")
            .first(where: { $0.contains("Effective biometrics for unlock") }) else { return true }
        return !line.hasSuffix("0")
    }

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenUnlocked() }
        // Preview without locking: plays the hint over the desktop, then the
        // unlock, e.g. `notifyutil`-style from a script or the terminal.
        dnc.addObserver(forName: Notification.Name("H1D3S1GN.MSG.previewTouchIDHint"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.screenUnlocked() }
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

    private func promptShown() {
        // The lock screen's own hint (or a prompt already shown) stays as is.
        guard hintView == nil, isEnabled, touchIDAvailable() else { return }
        guard presentHint(onLockScreen: false) else { return }
        showingForPrompt = true
    }

    /// No outcome is published, so read it from the input: Cancel, Esc and a
    /// typed password all end with a click or a key; a finger on the sensor
    /// produces neither. A finger gets the unlock animation, the rest a fade.
    private func promptClosed() {
        guard showingForPrompt, let view = hintView else { return }
        showingForPrompt = false
        func sinceLast(_ type: CGEventType) -> TimeInterval {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
        }
        let answeredByInput = min(sinceLast(.leftMouseDown), sinceLast(.keyDown)) < 0.5
        if answeredByInput { view.playHidden() } else { view.playUnlocked() }
        scheduleTeardown()
    }

    private func scheduleTeardown() {
        teardownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.teardown() }
        teardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchIDHintView.unlockDuration, execute: work)
    }

    private func screenLocked() {
        if playsLockSound, let lockSound {
            lockSound.stop()
            lockSound.play()
        }
        // Only point at the key when it will actually unlock the Mac; when a
        // password is required macOS's own field is the whole story. (The
        // 48-hour password rule isn't observable, so it can't be caught here.)
        guard isEnabled, LockScreenSpace.isAvailable,
              touchIDAvailable(), touchIDUnlocksMac() else { return }
        // A prompt's hint moves onto the lock screen with a fresh window.
        showingForPrompt = false
        guard presentHint(onLockScreen: true) else { return }

        // Too many failed scans lock Touch ID out mid-lock: drop the hint then.
        usabilityTimer?.invalidate()
        usabilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let view = self.hintView, self.touchIDLockedOut() else { return }
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

        let keyX = UserDefaults.standard.object(forKey: Self.keyPositionKey) as? Double ?? 0.925
        let view = TouchIDHintView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                   keyX: CGFloat(keyX))
        window.contentView = view
        window.orderFrontRegardless()

        if onLockScreen {
            guard let space = LockScreenSpace.present(window) else {
                window.orderOut(nil)
                return false
            }
            self.space = space
        } else {
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        self.window = window
        self.hintView = view
        view.playHint()
        return true
    }

    private func screenUnlocked() {
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
        if let space { LockScreenSpace.dismiss(space) }
        window?.orderOut(nil)
        window = nil
        hintView = nil
        space = nil
    }
}

// MARK: - View

/// iPad-style: a short bar on the screen edge right above the Touch ID key,
/// labelled "Touch ID", the way iPadOS marks its top-button sensor.
private final class TouchIDHintView: NSView {
    /// Time from unlock to teardown; the unlock is meant to feel instant.
    static let unlockDuration: TimeInterval = 0.35

    private let keyX: CGFloat
    private let bar = CALayer()
    private let label = CATextLayer()

    private static let barSize = CGSize(width: 58, height: 4)
    private static let barInset: CGFloat = 5

    init(frame: CGRect, keyX: CGFloat) {
        self.keyX = min(0.98, max(0.02, keyX))
        super.init(frame: frame)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let root = layer else { return }
        let x = bounds.width * keyX
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        bar.bounds = CGRect(origin: .zero, size: Self.barSize)
        bar.position = CGPoint(x: x, y: Self.barInset + Self.barSize.height / 2)
        bar.cornerRadius = Self.barSize.height / 2
        bar.backgroundColor = NSColor.white.cgColor
        bar.shadowColor = NSColor.black.cgColor
        bar.shadowOpacity = 0.35
        bar.shadowRadius = 3
        bar.shadowOffset = .zero
        bar.opacity = 0
        root.addSublayer(bar)

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = "Touch ID"
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
        label.string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        label.alignmentMode = .center
        label.contentsScale = scale
        label.bounds = CGRect(x: 0, y: 0, width: width, height: 16)
        label.position = CGPoint(x: x, y: Self.barInset + Self.barSize.height + 12)
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.4
        label.shadowRadius = 2
        label.shadowOffset = .zero
        label.opacity = 0
        root.addSublayer(label)
    }

    func playHint() {
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

    /// Instant: the label drops away and the bar slides down into the key.
    func playUnlocked() {
        bar.removeAllAnimations()
        label.removeAllAnimations()

        let labelGroup = CAAnimationGroup()
        let labelFall = CABasicAnimation(keyPath: "transform.translation.y")
        labelFall.toValue = -8
        let labelFade = CABasicAnimation(keyPath: "opacity")
        labelFade.fromValue = 1
        labelFade.toValue = 0
        labelGroup.animations = [labelFall, labelFade]
        labelGroup.duration = 0.18
        labelGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
        label.opacity = 0
        label.add(labelGroup, forKey: "leave")

        let barGroup = CAAnimationGroup()
        let widen = CABasicAnimation(keyPath: "bounds.size.width")
        widen.toValue = Self.barSize.width * 1.35
        let sink = CABasicAnimation(keyPath: "transform.translation.y")
        sink.toValue = -(Self.barInset + Self.barSize.height + 2)
        let barFade = CABasicAnimation(keyPath: "opacity")
        barFade.fromValue = 1
        barFade.toValue = 0
        barGroup.animations = [widen, sink, barFade]
        barGroup.duration = 0.28
        barGroup.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
        bar.opacity = 0
        bar.add(barGroup, forKey: "leave")
    }
}
