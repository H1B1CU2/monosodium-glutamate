import AppKit
import CoreGraphics
import CoreAudio

// MARK: - Shared HUD kind

/// The kind of system value an on-screen HUD bar represents. Shared by the
/// monitor (which produces events) and the renderer (which draws the bar).
enum SystemHUDKind {
    case volume
    case brightness
}

enum AudioOutputKind {
    case speaker
    case headphones
    case airPods
    case airPodsPro
}

// MARK: - SystemHUDMonitor
//
// Replaces the native macOS volume/brightness OSD ("Option A"). A session-level
// CGEventTap intercepts the hardware aux keys (NX_SYSDEFINED, subtype 8) for
// volume up/down/mute and brightness up/down. For the keys we own we *consume*
// the event so macOS never asks OSDUIHelper to draw its popup, then we apply the
// change ourselves (CoreAudio for audio, DisplayServices for the built-in panel),
// read the resulting value back, and notify `onChange`. Every other media key
// (play/pause, next/prev, keyboard backlight, …) is passed through untouched.
//
// The tap is added to the main run loop, so the C callback runs on the main
// thread and uses `MainActor.assumeIsolated` to reach the rest of the class.

final class SystemHUDMonitor {

    /// `(kind, value 0…1, muted, outputKind)` — fired on the main thread after a change.
    var onChange: ((SystemHUDKind, CGFloat, Bool, AudioOutputKind?) -> Void)?

    /// Asked on every transport key press: return `true` to take the key away
    /// from the system Now Playing app and deliver it via `onMediaKey` instead.
    /// Runs inside the tap callback, so it must answer from cached state only.
    var shouldRouteMediaKey: (() -> Bool)?

    /// A transport key that `shouldRouteMediaKey` claimed. Main thread.
    var onMediaKey: ((MediaKeyAction) -> Void)?

    /// Fired for every transport key press, whoever ends up handling it, so the
    /// music monitor can read Now Playing immediately instead of waiting out its
    /// current poll interval. Main thread.
    var onTransportKey: (() -> Void)?

    private let settings: AppSettings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The native volume feedback "tick" (the classic BezelServices tink),
    /// loaded once and restarted on each step for the staccato hold-to-repeat feel.
    private let volumeFeedbackSound: NSSound? = {
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSSound(contentsOfFile: path, byReference: false)
    }()

    // NX aux-control key codes (from IOKit/hidsystem/ev_keymap.h).
    private enum AuxKey {
        static let soundUp        = 0
        static let soundDown      = 1
        static let brightnessUp   = 2
        static let brightnessDown = 3
        static let mute           = 7
        static let play           = 16
        static let next           = 17
        static let previous       = 18
        /// Sent instead of next/previous while the key is held (scrub).
        static let fast           = 19
        static let rewind         = 20
    }

    private static let systemDefinedType: UInt32 = 14   // NX_SYSDEFINED

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SystemHUDMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { me.handle(type: type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }

        let mask = (CGEventMask(1) << SystemHUDMonitor.systemDefinedType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[MSG] SystemHUDMonitor: failed to create event tap — Accessibility permission required.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: Tap callback (main thread)

    /// Returns `true` to consume the event (hide the native OSD), `false` to pass through.
    @MainActor
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == SystemHUDMonitor.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { return false }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)

        // The HUD keys check `systemHUDEnabled` as well as their own toggle: the
        // tap also runs for media-key routing alone, and must then leave the
        // volume and brightness keys entirely to macOS.
        switch keyCode {
        case AuxKey.soundUp, AuxKey.soundDown:
            guard settings.systemHUDEnabled, settings.systemHUDVolume else { return false }
            if isDown { adjustVolume(up: keyCode == AuxKey.soundUp, fine: fine) }
            return true

        case AuxKey.mute:
            guard settings.systemHUDEnabled, settings.systemHUDVolume else { return false }
            if isDown && !isRepeat { toggleMute() }
            return true

        case AuxKey.brightnessUp, AuxKey.brightnessDown:
            guard settings.systemHUDEnabled, settings.systemHUDBrightness, builtinDisplay() != nil else { return false }
            if isDown { adjustBrightness(up: keyCode == AuxKey.brightnessUp, fine: fine) }
            return true

        case AuxKey.play, AuxKey.next, AuxKey.previous:
            // Tell the music monitor regardless of who ends up handling the key:
            // a transport press means playback state is about to change, and
            // reading immediately is what keeps the indicator feeling instant
            // when the poller has backed off. Never changes the return value.
            if isDown && !isRepeat { onTransportKey?() }
            guard shouldRouteMediaKey?() == true else { return false }
            if isDown && !isRepeat {
                switch keyCode {
                case AuxKey.play:     onMediaKey?(.playPause)
                case AuxKey.next:     onMediaKey?(.next)
                default:              onMediaKey?(.previous)
                }
            }
            return true

        // Swallowed while routing is active so a held next/previous can't leak
        // to the app we just took the key from. Music has no AppleScript scrub
        // command worth mapping these to, so they do nothing beyond that.
        case AuxKey.fast, AuxKey.rewind:
            return shouldRouteMediaKey?() == true

        default:
            return false
        }
    }

    // MARK: - Volume (CoreAudio)

    @MainActor
    private func adjustVolume(up: Bool, fine: Bool) {
        guard let device = defaultOutputDevice() else { return }
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        let grid: Float = fine ? 64.0 : 16.0
        var muted = isMuted(device)

        // Raising volume while muted unmutes, matching the system behavior.
        if up && muted { setMuted(device, false); muted = false }

        let current = volume(device) ?? 0
        var next = up ? current + step : current - step
        next = (next * grid).rounded() / grid
        next = max(0, min(1, next))
        setVolume(device, next)

        playVolumeFeedback()

        let actual = CGFloat(volume(device) ?? next)
        onChange?(.volume, actual, isMuted(device), audioOutputKind(for: device))
    }

    /// Play the native volume tick, honoring the system "Play feedback when
    /// volume is changed" preference (NSGlobalDomain `com.apple.sound.beep.feedback`,
    /// defaulting to on). Restarting allows rapid ticks while a key is held.
    @MainActor
    private func playVolumeFeedback() {
        let feedbackOn = (UserDefaults.standard.object(forKey: "com.apple.sound.beep.feedback") as? NSNumber)?.boolValue ?? true
        guard feedbackOn, let sound = volumeFeedbackSound else { return }
        sound.stop()
        sound.play()
    }

    @MainActor
    private func toggleMute() {
        guard let device = defaultOutputDevice() else { return }
        let newMuted = !isMuted(device)
        setMuted(device, newMuted)
        onChange?(.volume, CGFloat(volume(device) ?? 0), newMuted, audioOutputKind(for: device))
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// Bluetooth ProductIDs of Apple audio accessories (VendorID 0x004C),
    /// mapped to the closest icon this app draws. AirPods Max has no
    /// dedicated over-ear glyph in the symbol family, so it maps to the
    /// `.headphones` silhouette rather than the earbud-shaped `.airPods` one.
    /// IDs cross-checked against furiousMAC's continuity protocol docs and
    /// the BLE-DB dataset (the BLE Proximity Pairing model field is the same
    /// value byte-swapped).
    private static let appleAudioProductKinds: [UInt16: AudioOutputKind] = [
        0x200E: .airPodsPro, // AirPods Pro (1st gen)
        0x2014: .airPodsPro, // AirPods Pro (2nd gen, Lightning)
        0x2024: .airPodsPro, // AirPods Pro (2nd gen, USB-C) — confirmed live on this device
        0x2002: .airPods,    // AirPods (1st gen)
        0x200F: .airPods,    // AirPods (2nd gen)
        0x2013: .airPods,    // AirPods (3rd gen)
        0x2019: .airPods,    // AirPods (4th gen)
        0x201B: .airPods,    // AirPods (4th gen, ANC) — stemless like regular AirPods, not Pro-shaped
        0x200A: .headphones, // AirPods Max (Lightning)
        0x201F: .headphones, // AirPods Max (USB-C)
    ]

    private func audioOutputKind(for device: AudioDeviceID) -> AudioOutputKind {
        // For Bluetooth outputs, CoreAudio's ModelUID carries the accessory's
        // real Bluetooth ProductID/VendorID as "<pid> <vid>" hex (e.g.
        // "2024 4c" for AirPods Pro 2). That identifies the exact hardware
        // model of the device audio is actually routed to, unlike the
        // name-based checks below which break the moment the device is
        // renamed in Bluetooth settings.
        if audioDeviceTransportType(device) == kAudioDeviceTransportTypeBluetooth,
           let kind = appleAudioKindFromModelUID(device) {
            return kind
        }

        let name = audioDeviceName(device).lowercased()
        let uid = audioDeviceStringProperty(kAudioDevicePropertyDeviceUID, device: device).lowercased()
        let model = audioDeviceStringProperty(kAudioDevicePropertyModelUID, device: device).lowercased()
        let searchable = [name, uid, model].joined(separator: " ")

        if searchable.contains("airpods pro") || searchable.contains("airpod pro") || searchable.contains("airpodspro") {
            return .airPodsPro
        }
        if searchable.contains("airpods") || searchable.contains("airpod") {
            return .airPods
        }

        if searchable.contains("speaker") || searchable.contains("built-in") || searchable.contains("internal") || searchable.contains("macbook") {
            return .speaker
        }

        let headphoneHints = ["headphone", "headset", "earbud", "earphone", "buds", "beats"]
        if headphoneHints.contains(where: { searchable.contains($0) }) {
            return .headphones
        }

        if audioDeviceTransportType(device) == kAudioDeviceTransportTypeBluetooth {
            return .headphones
        }

        return .speaker
    }

    private func appleAudioKindFromModelUID(_ device: AudioDeviceID) -> AudioOutputKind? {
        let parts = audioDeviceStringProperty(kAudioDevicePropertyModelUID, device: device)
            .split(separator: " ")
        guard parts.count == 2,
              let pid = UInt16(parts[0], radix: 16),
              let vid = UInt16(parts[1], radix: 16),
              vid == 0x004C else { return nil }
        return Self.appleAudioProductKinds[pid]
    }

    private func audioDeviceName(_ device: AudioDeviceID) -> String {
        audioDeviceStringProperty(kAudioObjectPropertyName, device: device)
    }

    private func audioDeviceStringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return "" }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : ""
    }

    private func audioDeviceTransportType(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private func volume(_ device: AudioDeviceID) -> Float? {
        var main = volumeAddress(element: kAudioObjectPropertyElementMain)
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(device, &main),
           AudioObjectGetPropertyData(device, &main, 0, nil, &size, &value) == noErr {
            return value
        }
        // Fall back to the average of the front channels.
        var total: Float = 0, count: Float = 0
        for channel: AudioObjectPropertyElement in [1, 2] {
            var addr = volumeAddress(element: channel)
            var v = Float(0)
            var s = UInt32(MemoryLayout<Float>.size)
            if AudioObjectHasProperty(device, &addr),
               AudioObjectGetPropertyData(device, &addr, 0, nil, &s, &v) == noErr {
                total += v; count += 1
            }
        }
        return count > 0 ? total / count : nil
    }

    private func setVolume(_ device: AudioDeviceID, _ value: Float) {
        let v = max(0, min(1, value))
        var main = volumeAddress(element: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &main),
           AudioObjectIsPropertySettable(device, &main, &settable) == noErr, settable.boolValue {
            var val = v
            AudioObjectSetPropertyData(device, &main, 0, nil, UInt32(MemoryLayout<Float>.size), &val)
            return
        }
        for channel: AudioObjectPropertyElement in [1, 2] {
            var addr = volumeAddress(element: channel)
            var s: DarwinBoolean = false
            if AudioObjectHasProperty(device, &addr),
               AudioObjectIsPropertySettable(device, &addr, &s) == noErr, s.boolValue {
                var val = v
                AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &val)
            }
        }
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        var addr = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: - Brightness (DisplayServices, built-in panel)

    @MainActor
    private func adjustBrightness(up: Bool, fine: Bool) {
        guard let display = builtinDisplay() else { return }
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        let grid: Float = fine ? 64.0 : 16.0
        let current = DisplayServicesBridge.shared.getBrightness(display) ?? 0.5
        var next = up ? current + step : current - step
        next = (next * grid).rounded() / grid
        next = max(0, min(1, next))
        DisplayServicesBridge.shared.setBrightness(display, next)
        let actual = CGFloat(DisplayServicesBridge.shared.getBrightness(display) ?? next)
        onChange?(.brightness, actual, false, nil)
    }

    private func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - DisplayServices private framework bridge

/// Thin wrapper that `dlopen`s DisplayServices and resolves the brightness
/// symbols at runtime, so the build links no private framework.
private final class DisplayServicesBridge {
    static let shared = DisplayServicesBridge()

    private typealias GetFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias ChangedFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let get: GetFunc?
    private let set: SetFunc?
    private let changed: ChangedFunc?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        get = sym("DisplayServicesGetBrightness", GetFunc.self)
        set = sym("DisplayServicesSetBrightness", SetFunc.self)
        changed = sym("DisplayServicesBrightnessChanged", ChangedFunc.self)
    }

    func getBrightness(_ display: CGDirectDisplayID) -> Float? {
        guard let get else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    func setBrightness(_ display: CGDirectDisplayID, _ value: Float) {
        _ = set?(display, value)
        // Keep the system slider / menu bar in sync with the change.
        _ = changed?(display, value)
    }
}
