import AppKit
import IOKit.hid

extension Notification.Name {
    static let previewLidOpeningGlass = Notification.Name("MSG.previewLidOpeningGlass")
}

// MARK: - Angle mapping

/// Maps the physical MacBook lid angle to the visual state used by the opening
/// glass. Keeping this math pure makes the motion easy to regression-test.
enum LidGlassMapping {
    static let closedAngle = 15.0
    static let visuallyOpenAngle = 125.0

    static func openness(for angle: Double) -> CGFloat {
        CGFloat(min(1, max(0,
            (angle - closedAngle) / (visuallyOpenAngle - closedAngle))))
    }

    static func intensity(for angle: Double) -> CGFloat {
        intensity(forOpenness: openness(for: angle))
    }

    static func intensity(forOpenness openness: CGFloat) -> CGFloat {
        1 - materialization(forOpenness: openness)
    }

    /// Duo keeps the newly exposed half optically strong through most of the
    /// fold, then resolves the lensing into sharp content near the endpoint.
    /// This deliberately avoids the old full-travel opacity fade.
    static func materialization(forOpenness openness: CGFloat) -> CGFloat {
        smoothstep(0.72, 0.985, min(1, max(0, openness)))
    }

    /// Rotation of the virtual left display around the center seam. A real 3D
    /// layer transform consumes this value; horizontal scaling is not used.
    static func foldAngleDegrees(forOpenness openness: CGFloat) -> CGFloat {
        82 * (1 - min(1, max(0, openness)))
    }

    /// Geometry-bound edge light is strongest while the plate is visibly
    /// turning, then disappears with the material itself.
    static func rimIntensity(forOpenness openness: CGFloat) -> CGFloat {
        let p = min(1, max(0, openness))
        return sin(.pi * p) * intensity(forOpenness: p)
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat,
                                   _ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Lid angle sensor

/// Reads Apple's built-in lid-angle sensor through its standard HID sensor
/// collection (Apple VID 0x05AC, product 0x8104, Sensor/Orientation 0x20/0x8A).
/// The device can be replaced across sleep, so every `start()` performs a fresh
/// discovery instead of retaining a pre-sleep IOHIDDevice.
final class MacBookLidAngleSensor {
    var onAngle: ((Double) -> Void)?

    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var pollTimer: Timer?
    private var report = [UInt8](repeating: 0, count: 8)
    private(set) var isAvailable = false

    @discardableResult
    func start() -> Bool {
        stop()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0x0020,
            kIOHIDPrimaryUsageKey as String: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else {
            IOHIDManagerClose(manager, Self.noOptions)
            NSLog("[MSG Lid Glass] Lid-angle HID manager unavailable")
            return false
        }

        guard let device = devices.first(where: {
            IOHIDDeviceOpen($0, Self.noOptions) == kIOReturnSuccess
        }) else {
            IOHIDManagerClose(manager, Self.noOptions)
            NSLog("[MSG Lid Glass] Lid-angle HID device unavailable")
            return false
        }

        self.manager = manager
        self.device = device
        isAvailable = true
        NSLog("[MSG Lid Glass] Lid-angle sensor ready")
        poll() // Seed the first frame before waiting for the timer.

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        return true
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let device { IOHIDDeviceClose(device, Self.noOptions) }
        if let manager { IOHIDManagerClose(manager, Self.noOptions) }
        device = nil
        manager = nil
        isAvailable = false
    }

    private func poll() {
        guard let device else { return }
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, 1, &report, &length
        )
        guard result == kIOReturnSuccess, length >= 3 else { return }
        let raw = UInt16(report[2]) << 8 | UInt16(report[1])
        onAngle?(Double(raw))
    }

    deinit { stop() }
}

// MARK: - Full-screen opening glass

/// Coordinates the short, angle-driven opening effect. It is deliberately
/// independent of CornerWindow so sleep recovery or animation cannot disturb
/// Cornermizer's persistent overlays.
final class LidOpeningGlassController {
    private struct ReplaySample {
        let time: CGFloat
        let openness: CGFloat
    }

    private let settings: AppSettings
    private let sensor = MacBookLidAngleSensor()
    private var windows: [LidGlassWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var previewObserver: NSObjectProtocol?
    private var wakeWork: DispatchWorkItem?
    private var motionTimer: Timer?
    private var finishWork: DispatchWorkItem?
    private var lifetimeWork: DispatchWorkItem?
    private var wakeSequenceActive = false
    private var receivedAngle = false
    private var previewMode = false
    private var animateNextWake = false
    private var deferredWake = false
    private var deferredCaptureStartedAt: TimeInterval = 0
    private var deferredSamples: [(time: TimeInterval, openness: CGFloat)] = []
    private var deferredCaptureStopWork: DispatchWorkItem?
    private var replaySamples: [ReplaySample] = []
    private var replayDuration: TimeInterval = 0
    private var lastKnownAngle: Double?
    private var targetOpenness: CGFloat = 1
    private var displayedOpenness: CGFloat = 1
    private var motionStartedAt: TimeInterval = 0
    private var lastWakeAt: TimeInterval = -10
    private static let minimumRevealDuration: TimeInterval = 0.95

    init(settings: AppSettings) {
        self.settings = settings
        sensor.onAngle = { [weak self] angle in self?.consume(angle: angle) }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.prepareForSleep() })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.prepareForSleep() })

        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.scheduleWakeSequence() })
        }
        previewObserver = NotificationCenter.default.addObserver(
            forName: .previewLidOpeningGlass, object: nil, queue: .main
        ) { [weak self] _ in self?.beginWakeSequence(forceFallback: true) }
        PresentationState.shared.addObserver { [weak self] in
            self?.presentationStateChanged()
        }

        // Keep the sensor warm while the system is awake. No overlay is shown
        // until a real wake edge arms a sequence.
        if settings.lidOpeningGlassEnabled { _ = sensor.start() }

        // Opt-in visual probe for development without requiring a sleep cycle.
        if ProcessInfo.processInfo.environment["MSG_PREVIEW_LID_GLASS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.beginWakeSequence(forceFallback: true)
            }
        }
    }

    func settingsChanged() {
        if settings.lidOpeningGlassEnabled {
            if !sensor.isAvailable { _ = sensor.start() }
        } else {
            cancelActiveSequence()
            cancelDeferredWake()
            sensor.stop()
        }
    }

    func stop() {
        cancelActiveSequence()
        cancelDeferredWake()
        sensor.stop()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        previewObserver = nil
    }

    private func prepareForSleep() {
        // Distinguish closing the lid from an idle/display sleep. The sensor is
        // still reporting while the lid travels down, so this is reliable even
        // when AppleClamshellState has not flipped at the first notification.
        let clamshellClosed = Self.isClamshellClosed()
        animateNextWake = animateNextWake || clamshellClosed || (lastKnownAngle.map { $0 < 55 } ?? true)
        NSLog("[MSG Lid Glass] Sleep: angle=%@ clamshell=%d armed=%d",
              lastKnownAngle.map { String(format: "%.0f", $0) } ?? "unknown",
              clamshellClosed ? 1 : 0, animateNextWake ? 1 : 0)
        wakeWork?.cancel()
        sensor.stop()
        cancelActiveSequence()
        cancelDeferredWake()
    }

    private func scheduleWakeSequence() {
        // Idle sleep also closes the HID device. Always rediscover it on wake.
        if settings.lidOpeningGlassEnabled, !sensor.isAvailable { _ = sensor.start() }
        guard settings.lidOpeningGlassEnabled, animateNextWake else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWakeAt > 0.75 else { return } // Coalesce both wake notifications.
        lastWakeAt = now
        NSLog("[MSG Lid Glass] Closed-lid wake detected")
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if PresentationState.shared.canPresent {
                self.beginWakeSequence()
            } else {
                self.beginDeferredWakeCapture()
            }
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// The login window sits above all ordinary app windows. Capture the real
    /// hinge trajectory while hidden, then replay it as soon as the user's
    /// session becomes visible instead of completing an unseen animation.
    private func beginDeferredWakeCapture() {
        cancelActiveSequence()
        deferredWake = true
        animateNextWake = false
        deferredSamples.removeAll(keepingCapacity: true)
        deferredCaptureStartedAt = ProcessInfo.processInfo.systemUptime
        _ = sensor.start()
        NSLog("[MSG Lid Glass] Wake hidden by lock screen; recording hinge")

        deferredCaptureStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.deferredWake else { return }
            // Keep the pending replay, but stop a private sensor from polling
            // forever if the user leaves the Mac locked.
            self.sensor.stop()
        }
        deferredCaptureStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func presentationStateChanged() {
        guard PresentationState.shared.canPresent else {
            if wakeSequenceActive { cancelActiveSequence() }
            return
        }
        guard deferredWake, settings.lidOpeningGlassEnabled else { return }
        let replay = makeReplayProfile()
        cancelDeferredWake(keepSamples: false)
        beginWakeSequence(forceFallback: replay.isEmpty, replay: replay)
    }

    private func beginWakeSequence(forceFallback: Bool = false,
                                   replay: [ReplaySample] = []) {
        guard settings.lidOpeningGlassEnabled else { return }
        cancelActiveSequence()
        animateNextWake = false
        wakeSequenceActive = true
        receivedAngle = false
        previewMode = forceFallback || !replay.isEmpty
        replaySamples = replay
        replayDuration = replay.isEmpty ? 0 : replayDuration(for: replay)
        targetOpenness = (forceFallback || !replay.isEmpty) ? 1 : 0
        displayedOpenness = 0
        motionStartedAt = CACurrentMediaTime()
        NSLog("[MSG Lid Glass] Reveal began%@", forceFallback ? " (preview)" : "")
        ensureWindows()
        windows.forEach {
            $0.update(openness: 0,
                      intensity: LidGlassMapping.intensity(forOpenness: 0))
        }
        startMotionTimer()

        let sensorReady = !forceFallback && replay.isEmpty && sensor.start()
        if !sensorReady {
            targetOpenness = 1
        } else if replay.isEmpty {
            // If the HID report never arrives after wake, degrade gracefully to
            // the same visual instead of leaving the feature silent.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.wakeSequenceActive, !self.receivedAngle else { return }
                self.targetOpenness = 1
            }
            finishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        // A partially opened lid can be held indefinitely. The glass must never
        // obstruct normal work, so it has a hard visual lifetime.
        let lifetime = DispatchWorkItem { [weak self] in
            guard self?.wakeSequenceActive == true else { return }
            self?.finish()
        }
        lifetimeWork = lifetime
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: lifetime)
    }

    private func consume(angle: Double) {
        lastKnownAngle = angle
        if deferredWake {
            let now = ProcessInfo.processInfo.systemUptime
            let sample = (time: now - deferredCaptureStartedAt,
                          openness: LidGlassMapping.openness(for: angle))
            if deferredSamples.last.map({ abs($0.openness - sample.openness) > 0.002 }) ?? true {
                deferredSamples.append(sample)
            }
            return
        }
        guard wakeSequenceActive, !previewMode else { return }
        let firstSample = !receivedAngle
        receivedAngle = true
        finishWork?.cancel()
        finishWork = nil

        targetOpenness = LidGlassMapping.openness(for: angle)
        if firstSample {
            NSLog("[MSG Lid Glass] First wake angle %.0f degrees, target %.2f",
                  angle, targetOpenness)
        }
    }

    /// The sensor may first become readable only after the physical lid is
    /// already open. A time ceiling keeps that first large angle sample from
    /// skipping the whole visual, while slower openings still follow the live
    /// physical angle exactly.
    private func startMotionTimer() {
        motionTimer?.invalidate()
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
            guard let self, self.wakeSequenceActive else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.motionStartedAt
            let linear = min(1, CGFloat(elapsed / Self.minimumRevealDuration))
            let desired: CGFloat
            let trajectoryFinished: Bool
            if !self.replaySamples.isEmpty {
                let replayTime = min(1, CGFloat(elapsed / self.replayDuration))
                desired = self.replayedOpenness(at: replayTime)
                trajectoryFinished = replayTime >= 1
            } else {
                let timeCeiling = Easing.outQuart(linear)
                desired = min(self.targetOpenness, timeCeiling)
                trajectoryFinished = linear >= 1
            }
            // Smooth small HID quantisation steps without adding a long tail.
            self.displayedOpenness += (desired - self.displayedOpenness) * 0.34
            if abs(desired - self.displayedOpenness) < 0.002 {
                self.displayedOpenness = desired
            }
            self.windows.forEach {
                $0.update(openness: self.displayedOpenness,
                          intensity: LidGlassMapping.intensity(
                            forOpenness: self.displayedOpenness))
            }
            if trajectoryFinished,
               self.targetOpenness >= 0.985,
               self.displayedOpenness >= 0.975 {
                timer.invalidate()
                self.motionTimer = nil
                self.finish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func ensureWindows() {
        guard windows.isEmpty else { return }
        let screens = NSScreen.screens.filter(\.isBuiltin)
        windows = screens.map(LidGlassWindow.init(screen:))
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func finish() {
        guard wakeSequenceActive else { return }
        lifetimeWork?.cancel(); lifetimeWork = nil
        wakeSequenceActive = false
        previewMode = false
        motionTimer?.invalidate()
        motionTimer = nil
        replaySamples.removeAll()
        replayDuration = 0
        // The plate has already materialized to zero at the open angle. Do not
        // append an unrelated disappear animation after the physical motion.
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if settings.lidOpeningGlassEnabled, !sensor.isAvailable,
           PresentationState.shared.canPresent {
            _ = sensor.start()
        }
    }

    private func cancelActiveSequence() {
        lifetimeWork?.cancel(); lifetimeWork = nil
        wakeSequenceActive = false
        receivedAngle = false
        previewMode = false
        wakeWork?.cancel(); wakeWork = nil
        finishWork?.cancel(); finishWork = nil
        motionTimer?.invalidate(); motionTimer = nil
        replaySamples.removeAll()
        replayDuration = 0
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func cancelDeferredWake(keepSamples: Bool = false) {
        deferredWake = false
        deferredCaptureStopWork?.cancel()
        deferredCaptureStopWork = nil
        if !keepSamples { deferredSamples.removeAll() }
    }

    private func makeReplayProfile() -> [ReplaySample] {
        let samples = deferredSamples
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last,
              last.openness - first.openness > 0.08
        else { return [] }

        let duration = max(0.001, last.time - first.time)
        var profile = samples.map {
            ReplaySample(time: CGFloat(($0.time - first.time) / duration),
                         openness: $0.openness)
        }
        if profile[0].openness > 0.02 {
            profile.insert(ReplaySample(time: 0, openness: 0), at: 0)
        }
        if profile.last?.openness ?? 0 < 0.995 {
            profile.append(ReplaySample(time: 1, openness: 1))
        }
        return profile
    }

    private func replayDuration(for samples: [ReplaySample]) -> TimeInterval {
        guard samples.count > 1 else { return Self.minimumRevealDuration }
        return 1.05
    }

    private func replayedOpenness(at time: CGFloat) -> CGFloat {
        guard let first = replaySamples.first else { return time }
        if time <= first.time { return first.openness }
        for (a, b) in zip(replaySamples, replaySamples.dropFirst()) where time <= b.time {
            let span = max(0.0001, b.time - a.time)
            let local = (time - a.time) / span
            return a.openness + (b.openness - a.openness) * local
        }
        return replaySamples.last?.openness ?? 1
    }

    private static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (value as? Bool) == true
    }

    deinit { stop() }
}

private final class LidGlassWindow: NSWindow {
    private let glassView: LidGlassView

    init(screen: NSScreen) {
        glassView = LidGlassView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = NSWindow.Level(Int(kCGAssistiveTechHighWindowLevel) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
        contentView = glassView
    }

    func update(openness: CGFloat, intensity: CGFloat) {
        alphaValue = 1
        glassView.update(openness: openness, intensity: intensity)
        if !isVisible { orderFrontRegardless() }
    }
}

/// Duo's defining composition is asymmetric: one half remains sharp while the
/// newly exposed half pivots out of the center hinge as a rounded glass plate.
/// The previous implementation blurred the entire display, which removed both
/// the spatial reference and the fold illusion.
private final class LidGlassView: NSView {
    private let plate = NSView()
    private let chrome = LidDuoGlassChromeView()
    private var glassSurface: NSView!
    private var nativeGlass: AnyObject?
    private var openness: CGFloat = 0
    private var intensity: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        plate.wantsLayer = true
        plate.layer?.masksToBounds = false
        addSubview(plate)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = NSColor.white.withAlphaComponent(0.018)
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            glass.contentView = content
            glassSurface = glass
            nativeGlass = glass
        } else {
            let fallback = NSVisualEffectView()
            fallback.blendingMode = .behindWindow
            fallback.material = .fullScreenUI
            fallback.state = .active
            glassSurface = fallback
        }
        plate.addSubview(glassSurface)
        plate.addSubview(chrome)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    func update(openness: CGFloat, intensity: CGFloat) {
        self.openness = min(1, max(0, openness))
        self.intensity = min(1, max(0, intensity))
        needsLayout = true
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    private func applyGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let horizontalInset = max(18, bounds.width * 0.028)
        let verticalInset = max(24, bounds.height * 0.055)
        let seamGap = max(3, bounds.width * 0.0025)
        let plateSize = CGSize(width: bounds.midX - horizontalInset - seamGap,
                               height: bounds.height - verticalInset * 2)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        plate.layer?.transform = CATransform3DIdentity
        plate.frame = CGRect(x: horizontalInset, y: verticalInset,
                             width: plateSize.width, height: plateSize.height)
        plate.bounds = CGRect(origin: .zero, size: plateSize)
        plate.layer?.anchorPoint = CGPoint(x: 1, y: 0.5)
        plate.layer?.position = CGPoint(x: bounds.midX - seamGap,
                                        y: bounds.midY)

        glassSurface.frame = plate.bounds
        chrome.frame = plate.bounds

        let cornerRadius = min(42, max(24, plateSize.height * 0.045))
        if #available(macOS 26.0, *),
           let glass = nativeGlass as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            glassSurface.wantsLayer = true
            glassSurface.layer?.cornerRadius = cornerRadius
            glassSurface.layer?.cornerCurve = .continuous
            glassSurface.layer?.masksToBounds = true
        }

        var transform = CATransform3DIdentity
        transform.m34 = -1 / max(900, bounds.width * 1.15)
        let radians = LidGlassMapping.foldAngleDegrees(forOpenness: openness)
            * .pi / 180
        transform = CATransform3DRotate(transform, -radians, 0, 1, 0)
        plate.layer?.transform = transform
        plate.alphaValue = intensity

        chrome.cornerRadius = cornerRadius
        chrome.openness = openness
        chrome.intensity = intensity
        chrome.rimIntensity = LidGlassMapping.rimIntensity(forOpenness: openness)
        chrome.needsDisplay = true
    }
}

/// Restrained, geometry-bound lighting for the native glass plate. Every mark
/// rotates with the virtual display; nothing sweeps independently over the
/// desktop.
private final class LidDuoGlassChromeView: NSView {
    var openness: CGFloat = 0
    var intensity: CGFloat = 1
    var rimIntensity: CGFloat = 0
    var cornerRadius: CGFloat = 32
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        context.clear(bounds)
        guard rect.width > 2, rect.height > 2 else { return }

        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()

        // A small ambient lift helps the plate read over very dark desktops,
        // while the native material supplies the actual sampling and lensing.
        let ambient = [
            NSColor.white.withAlphaComponent(0.018 * intensity).cgColor,
            NSColor(calibratedRed: 0.48, green: 0.60, blue: 0.82,
                    alpha: 0.025 * intensity).cgColor,
            NSColor.black.withAlphaComponent(0.035 * intensity).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: ambient,
                                     locations: [0, 0.62, 1]) {
            context.drawLinearGradient(gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }

        // The strongest specular response lives at the physical seam and grows
        // only while that edge turns toward the viewer.
        let seamWidth = max(10, rect.width * 0.045)
        let seamAlpha = (0.08 + 0.30 * rimIntensity) * intensity
        let seamColors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(seamAlpha * 0.20).cgColor,
            NSColor.white.withAlphaComponent(seamAlpha).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: seamColors,
                                     locations: [0, 0.72, 1]) {
            context.drawLinearGradient(gradient,
                start: CGPoint(x: rect.maxX - seamWidth, y: rect.midY),
                end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        }
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(
            (0.08 + 0.20 * rimIntensity) * intensity).cgColor)
        context.setLineWidth(1.25)
        context.strokePath()

        // A darker hairline beside the hinge supplies depth without dimming the
        // fixed right half of the desktop.
        context.setStrokeColor(NSColor.black.withAlphaComponent(
            (0.12 + 0.18 * (1 - openness)) * intensity).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.maxX - 0.5,
                                 y: rect.minY + cornerRadius))
        context.addLine(to: CGPoint(x: rect.maxX - 0.5,
                                    y: rect.maxY - cornerRadius))
        context.strokePath()
    }
}
