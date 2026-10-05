import AppKit
import IOKit

/// Watches the trackpad's raw contacts for a multi-finger vertical swipe, and
/// reports it continuously — began, every change, ended — so a surface can
/// follow the fingers rather than react once at the end.
///
/// macOS publishes no system-wide gesture API, and a CGEvent tap only sees
/// swipes the Dock has already claimed for Mission Control or App Exposé. So
/// this reads contact frames from MultitouchSupport directly — resolved at
/// runtime like `HapticFeedback`, so the build links no private framework.
///
/// Costs nothing at rest: MultitouchSupport only calls back while fingers are
/// on the surface. New trackpads (a Magic Trackpad connecting later) are
/// picked up by an IOKit notification, not by polling.
final class TrackpadSwipeMonitor {
    static let shared = TrackpadSwipeMonitor()

    // All on the main thread, in order. `offset` is the fingers' travel since
    // they settled, as a share of the trackpad's height: positive up (away
    // from the user), negative down. Began always comes with its first change.
    var onVerticalSwipeBegan: (() -> Void)?
    var onVerticalSwipeChanged: ((CGFloat) -> Void)?
    var onVerticalSwipeEnded: (() -> Void)?

    // Horizontal swipe: `offset` is the fingers' travel since they settled,
    // as a share of the trackpad's width: positive right, negative left.
    var onHorizontalSwipeBegan: (() -> Void)?
    /// (x, y): sideways travel as above, plus vertical travel (positive up)
    /// so a surface can read a downward pull during the swipe.
    var onHorizontalSwipeChanged: ((CGFloat, CGFloat) -> Void)?
    var onHorizontalSwipeEnded: (() -> Void)?

    /// Whether macOS itself has a vertical swipe (Mission Control / App Exposé)
    /// on the finger count this monitor follows. Nothing here can stop the
    /// system's gesture from running as well, so settings warns about it.
    static var systemClaimsVerticalSwipe: Bool {
        let key = requiredFingers == 3 ? "TrackpadThreeFingerVertSwipeGesture" : "TrackpadFourFingerVertSwipeGesture"
        // Unset means the system default, which is on.
        return trackpadDomains.contains { domain in
            (UserDefaults(suiteName: domain)?.object(forKey: key) as? Int ?? 2) != 0
        }
    }

    /// Whether macOS itself has a horizontal swipe (Switch between full-screen apps / spaces)
    /// on `fingers`. macOS moves its three-finger swipe to four while
    /// three-finger drag is on, and stores that under the four-finger key.
    static func systemClaimsHorizontalSwipe(fingers: Int) -> Bool {
        let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadFourFingerHorizSwipeGesture"
        return trackpadDomains.contains { domain in
            (UserDefaults(suiteName: domain)?.object(forKey: key) as? Int ?? 2) != 0
        }
    }

    // MARK: MultitouchSupport

    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFunc = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFunc = @convention(c) (UnsafeRawPointer, ContactCallback) -> Void
    private typealias StartFunc = @convention(c) (UnsafeRawPointer, Int32) -> Int32
    private typealias StopFunc = @convention(c) (UnsafeRawPointer) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
    }
    private static let createList = symbol("MTDeviceCreateList", CreateListFunc.self)
    private static let register = symbol("MTRegisterContactFrameCallback", RegisterFunc.self)
    private static let unregister = symbol("MTUnregisterContactFrameCallback", RegisterFunc.self)
    private static let startDevice = symbol("MTDeviceStart", StartFunc.self)
    private static let stopDevice = symbol("MTDeviceStop", StopFunc.self)

    /// MultitouchSupport's per-contact record. The layout is the one every
    /// MultitouchSupport client relies on; `isLayoutSane` refuses to read
    /// frames if Swift ever lays it out differently.
    private struct Point { var x: Float; var y: Float }
    private struct Vector { var position: Point; var velocity: Point }
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        /// 0…1 across the surface, origin at the bottom-left — the edge
        /// nearest the user — so a swipe down lowers `y`.
        var normalized: Vector
        var size: Float
        var zero1: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absolute: Vector
        var zero2: Int32
        var zero3: Int32
        var density: Float
    }
    private static let isLayoutSane = MemoryLayout<Touch>.stride == 96

    /// `MakeTouch` and `Touching`: a finger actually down, not hovering or lifting.
    private static let touchingStates: ClosedRange<Int32> = 3...4

    // MARK: Gesture rules

    /// Vertical travel, as a share of the trackpad's height, that makes the
    /// contact a swipe. Small, so the surface appears as the fingers start.
    static let recognitionTravel: Float = 0.05
    /// Sideways drift allowed before recognition, as a share of the travel.
    private static let maxDrift: Float = 0.7
    /// Slower than this to get going is a rest, not a swipe.
    private static let maxDuration: Double = 0.6
    /// How long fingers on the horizontal swipe's count must rest before the
    /// HUD opens.
    private static let holdToOpen: Double = 0.5
    /// Centroid travel still counted as resting during that hold.
    private static let stillTravel: Float = 0.025

    private enum SwipeAxis {
        case vertical
        case horizontal
    }

    private struct Tracker {
        var start: Point?
        var startTime: Double = 0
        /// Fingers down when `start` was taken. Decides which axis may be
        /// recognized, since the two can want different counts.
        var fingers = 0
        var axis: SwipeAxis?
        /// Recognized: changes flow until the fingers lift.
        var swiping = false
        /// Ended, or turned out to be some other gesture: nothing more until
        /// every finger has lifted.
        var done = false
    }

    private let lock = NSLock()
    private var trackers: [Int: Tracker] = [:]
    /// Vertical (tab) swipe fingers: follows three-finger drag.
    private var fingers = 3
    /// Horizontal (deskspace) swipe fingers, chosen in settings. Guarded by `lock`.
    private var horizontalFingerCount = 3

    /// Whether the vertical swipe is in use. Off, it never shares a finger
    /// count with the horizontal one. Guarded by `lock`.
    private var verticalEnabled = true

    /// A partial lift ends the old swipe, but does not require every finger
    /// to leave the pad before another deliberate swipe can begin.
    static func canRearm(withDownCount down: Int, verticalCount: Int,
                         horizontalCount: Int) -> Bool {
        let counts = [verticalCount, horizontalCount].filter { $0 > 0 }
        return down < (counts.min() ?? Int.max)
    }

    func setVerticalEnabled(_ enabled: Bool) {
        lock.lock()
        verticalEnabled = enabled
        lock.unlock()
    }

    /// Sets the horizontal swipe's finger count (3 or 4). Takes effect on
    /// the next contact.
    func setHorizontalFingers(_ count: Int) {
        lock.lock()
        horizontalFingerCount = count == 4 ? 4 : 3
        lock.unlock()
    }

    private var devices: [UnsafeRawPointer] = []
    private var deviceList: CFArray?
    private var running = false
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var wakeObserver: Any?
    private var rescanWork: DispatchWorkItem?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !running, Self.isLayoutSane, Self.createList != nil else { return }
        running = true
        GestureEventSuppressor.shared.install()
        startDevices()
        watchForDevices()
        // Contact callbacks can go quiet across sleep; start the devices afresh.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRescan() }
    }

    func stop() {
        guard running else { return }
        running = false
        GestureEventSuppressor.shared.uninstall()
        PointerFreeze.set(false)
        rescanWork?.cancel()
        rescanWork = nil
        stopDevices()
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func startDevices() {
        guard let createList = Self.createList, let register = Self.register,
              let startDevice = Self.startDevice,
              let list = createList()?.takeUnretainedValue() else { return }
        lock.lock()
        fingers = Self.requiredFingers
        trackers = [:]
        lock.unlock()
        deviceList = list
        devices = (0..<CFArrayGetCount(list)).compactMap { CFArrayGetValueAtIndex(list, $0) }
        for device in devices {
            register(device, contactFrameCallback)
            _ = startDevice(device, 0)
        }
    }

    private func stopDevices() {
        for device in devices {
            Self.unregister?(device, contactFrameCallback)
            _ = Self.stopDevice?(device)
        }
        devices = []
        deviceList = nil
    }

    /// The system's own swipes move to four fingers while three-finger drag
    /// is on, because three fingers now drag. Follow it, or every three-finger
    /// drag downward would switch tabs.
    private static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad",
                                          "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    private static var requiredFingers: Int {
        let threeFingerDrag = trackpadDomains.contains {
            UserDefaults(suiteName: $0)?.bool(forKey: "TrackpadThreeFingerDrag") == true
        }
        return threeFingerDrag ? 4 : 3
    }

    // MARK: Device changes

    private func watchForDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, kind, IOServiceMatching("AppleMultitouchDevice"),
                { refcon, iterator in
                    TrackpadSwipeMonitor.drain(iterator)
                    guard let refcon else { return }
                    Unmanaged<TrackpadSwipeMonitor>.fromOpaque(refcon).takeUnretainedValue().scheduleRescan()
                },
                refcon, &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // Draining arms the notification; the devices present now were
            // already started above.
            Self.drain(iterator)
            iterators.append(iterator)
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// A device that has only just matched isn't ready to start yet, and one
    /// plug-in raises several notifications; settle, then start everything once.
    private func scheduleRescan() {
        guard running else { return }
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.stopDevices()
            self.startDevices()
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Recognition

    /// Runs on MultitouchSupport's thread, once per contact frame.
    fileprivate func process(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?,
                             count: Int, timestamp: Double) {
        let key = device.map { Int(bitPattern: $0) } ?? 0
        var down = 0
        var sum = Point(x: 0, y: 0)
        if let touches {
            let stride = MemoryLayout<Touch>.stride
            for index in 0..<count {
                let touch = touches.load(fromByteOffset: index * stride, as: Touch.self)
                guard Self.touchingStates.contains(touch.state) else { continue }
                down += 1
                sum.x += touch.normalized.position.x
                sum.y += touch.normalized.position.y
            }
        }

        lock.lock()
        defer { lock.unlock() }
        // Runs after the tracker is stored (defers unwind in reverse): while
        // any swipe is live, the app under the pointer gets no scroll or
        // gesture events from these fingers.
        defer {
            GestureEventSuppressor.shared.setActive(trackers.values.contains { $0.swiping })
            // The pointer holds still from the moment the fingers settle
            // until they lift — three fingers also drag the pointer (with
            // three-finger drag on), and it crept during every swipe. A
            // contact that turns out not to be a swipe lets it go at once.
            PointerFreeze.set(trackers.values.contains { $0.start != nil && !$0.done })
        }
        var tracker = trackers[key] ?? Tracker()
        guard down > 0 else {
            if tracker.swiping {
                let axis = tracker.axis
                post { monitor in
                    if axis == .vertical { monitor.onVerticalSwipeEnded?() }
                    else if axis == .horizontal { monitor.onHorizontalSwipeEnded?() }
                }
            }
            trackers[key] = nil
            return
        }
        defer { trackers[key] = tracker }
        // 0 = the vertical swipe is off, so it never competes for a count.
        let verticalCount = verticalEnabled ? fingers : 0
        let horizontalCount = horizontalFingerCount
        if tracker.done {
            if Self.canRearm(withDownCount: down, verticalCount: verticalCount,
                             horizontalCount: horizontalCount) {
                tracker = Tracker()
            }
            return
        }

        if tracker.swiping {
            guard down == tracker.fingers else {
                // A finger lifting (or landing) mid-swipe is the swipe letting go.
                let axis = tracker.axis
                tracker.swiping = false
                tracker.done = !Self.canRearm(withDownCount: down,
                                               verticalCount: verticalCount,
                                               horizontalCount: horizontalCount)
                if !tracker.done { tracker = Tracker() }
                post { monitor in
                    if axis == .vertical { monitor.onVerticalSwipeEnded?() }
                    else if axis == .horizontal { monitor.onHorizontalSwipeEnded?() }
                }
                return
            }
        } else if down != verticalCount && down != horizontalCount {
            // Fingers land one at a time, so an unused count is fine until the
            // contact has begun. More than either swipe uses, or one lifting
            // after it began, is not this.
            if down > max(verticalCount, horizontalCount) || tracker.start != nil {
                tracker.done = true
            }
            return
        } else if tracker.start != nil, down != tracker.fingers {
            // Three settled, then a fourth landed: start over as a four-finger
            // contact. Fewer than it began with is a finger lifting early.
            guard down > tracker.fingers else {
                tracker.done = true
                return
            }
            tracker.start = nil
        }

        let centroid = Point(x: sum.x / Float(down), y: sum.y / Float(down))
        guard let start = tracker.start else {
            tracker.start = centroid
            tracker.startTime = timestamp
            tracker.fingers = down
            return
        }

        if tracker.swiping, let axis = tracker.axis {
            switch axis {
            case .vertical:
                let offset = CGFloat(centroid.y - start.y)
                post { $0.onVerticalSwipeChanged?(offset) }
            case .horizontal:
                let offset = CGFloat(centroid.x - start.x)
                let rise = CGFloat(centroid.y - start.y)
                post { $0.onHorizontalSwipeChanged?(offset, rise) }
            }
            return
        }

        let travelY = abs(centroid.y - start.y)
        let travelX = abs(centroid.x - start.x)

        let verticalAllowed = tracker.fingers == verticalCount
        let horizontalAllowed = tracker.fingers == horizontalCount

        // The horizontal swipe opens only on a hold: fingers resting still
        // for `holdToOpen`. A quick swipe never gets that far, so it can't
        // scrub and switch. Once open, travel is measured from here.
        if horizontalAllowed, travelX < Self.stillTravel, travelY < Self.stillTravel {
            if timestamp - tracker.startTime >= Self.holdToOpen {
                tracker.axis = .horizontal
                tracker.swiping = true
                tracker.start = centroid
                post {
                    NSLog("[MSG Swipe Input] horizontal hold recognized")
                    $0.onHorizontalSwipeBegan?()
                    $0.onHorizontalSwipeChanged?(0, 0)
                }
            }
            return
        }

        if travelY >= Self.recognitionTravel, travelX <= travelY * Self.maxDrift {
            // Vertical swipes still start on movement.
            guard verticalAllowed else { tracker.done = true; return }
            tracker.axis = .vertical
            tracker.swiping = true
            let offset = CGFloat(centroid.y - start.y)
            post {
                NSLog("[MSG Swipe Input] vertical recognized offset=%.4f", Double(offset))
                $0.onVerticalSwipeBegan?()
                $0.onVerticalSwipeChanged?(offset)
            }
        } else if !verticalAllowed || travelX >= Self.recognitionTravel
                    || timestamp - tracker.startTime > Self.maxDuration {
            // Moved before the hold finished — a quick sideways swipe, or any
            // movement on a count only the hold uses — or rested too long
            // for a vertical swipe: not ours.
            tracker.done = true
        }
    }

    private func post(_ body: @escaping (TrackpadSwipeMonitor) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }
}

/// Detaches the pointer from the trackpad while a swipe's fingers are down.
/// Called from the contact callback's thread; the switch itself is one
/// WindowServer call, so it takes effect before the next finger frame.
fileprivate enum PointerFreeze {
    private static let lock = NSLock()
    private static var frozen = false
    private static var lastFrame: CFTimeInterval = 0
    private static var watchdog: DispatchSourceTimer?

    static func set(_ freeze: Bool) {
        lock.lock()
        defer { lock.unlock() }
        lastFrame = CACurrentMediaTime()
        guard freeze != frozen else { return }
        frozen = freeze
        CGAssociateMouseAndMouseCursorPosition(freeze ? 0 : 1)
        watchdog?.cancel()
        watchdog = nil
        guard freeze else { return }
        // Frames arrive continuously while fingers rest on the pad; if they
        // stop (the trackpad slept, the device went away), never leave the
        // pointer stuck.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            lock.lock()
            defer { lock.unlock() }
            guard frozen, CACurrentMediaTime() - lastFrame > 0.4 else { return }
            frozen = false
            CGAssociateMouseAndMouseCursorPosition(1)
            watchdog?.cancel()
            watchdog = nil
        }
        watchdog = timer
        timer.resume()
    }
}

/// A C callback can't capture, so it reaches the monitor through `shared`.
private let contactFrameCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32 = { device, touches, count, timestamp, _ in
    TrackpadSwipeMonitor.shared.process(device: device, touches: touches,
                                        count: Int(count), timestamp: timestamp)
    return 0
}

// MARK: - GestureEventSuppressor

/// Swallows the scroll and gesture events a multi-finger swipe also produces
/// — the scrolling, panning, zooming or page swiping the app under the
/// pointer would otherwise do — while `TrackpadSwipeMonitor` owns the swipe.
///
/// An active session event tap on its own thread, so a busy main thread (the
/// HUD opening) never stalls the system's input. Disabled at rest: events
/// don't pass through it at all until a swipe begins.
final class GestureEventSuppressor {
    static let shared = GestureEventSuppressor()

    private let lock = NSLock()
    private var active = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    private init() {}

    /// Scroll wheel plus NSEvent's rotate (18), gesture (29), magnify (30),
    /// swipe (31) and smart magnify (32). Begin/end gesture (19/20) always
    /// pass: they bracket every gesture, and swallowing one half of a pair
    /// leaves whoever tracks them waiting for an end that never comes.
    private static let mask: CGEventMask = [22, 18, 29, 30, 31, 32]
        .reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1)) }

    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard tap == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            // Session level only. At the HID level, dropping gesture events
            // mid-stream left WindowServer's own gesture tracking with a
            // gesture that began and never ended, and the native swipe
            // between Desktops stopped working until logout.
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<GestureEventSuppressor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("[MSG Swipe] Could not create gesture suppression tap (Accessibility permission?)")
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self?.lock.lock()
            self?.runLoop = loop
            self?.lock.unlock()
            CFRunLoopRun()
        }
        thread.name = "MSG gesture suppression"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }

    /// Called on every contact frame; only touches the tap on a change.
    func setActive(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard active != on else { return }
        active = on
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let on = active
        let port = tap
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if on, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return on ? nil : Unmanaged.passUnretained(event)
    }
}
