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
    /// A monitor's own speakers (HDMI / DisplayPort audio), drawn as a
    /// Creative Pebble rather than the generic speaker.
    case displaySpeaker
    /// Nothing Headphone (a) / (1), drawn as its own front view.
    case nothingHeadphone
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
    /// Which transport key went down (never a repeat), for the key HUD.
    /// Fires whoever handles the key; never changes the return value.
    var onTransportAction: ((MediaKeyAction) -> Void)?
    /// Every aux key press, repeats included (NX key code), for the Edge Keys
    /// strip to light the key. Never changes the return value.
    var onAuxKeyDown: ((Int, Bool) -> Void)?
    /// Asked first for every aux key event `(code, isDown, isRepeat)`: true
    /// takes the key for an Edge Keys second-row action.
    var auxKeyOverride: ((Int, Bool, Bool) -> Bool)?

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
        MainActor.assumeIsolated { startOutsideVolume() }
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
        MainActor.assumeIsolated { stopOutsideVolume() }
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
              let nsEvent = NSEvent(cgEvent: event) else { return false }
        guard nsEvent.subtype.rawValue == 8 else { return false }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF0000) >> 16)
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        // A control key an Edge Keys action posted (see EdgeKeyActions) does
        // its own job, never another remapped one, and lights no cap.
        let ownEvent = event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        if !ownEvent, auxKeyOverride?(keyCode, isDown, isRepeat) == true { return true }
        if isDown { onAuxKeyDown?(keyCode, ownEvent) }

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
            guard settings.systemHUDEnabled, settings.systemHUDBrightness else { return false }
            let up = keyCode == AuxKey.brightnessUp
            // One control for every screen: the keys set the built-in panel and
            // external monitors follow it (ExternalBrightnessSync).
            if builtinDisplay() != nil {
                if isDown { adjustBrightness(up: up, fine: fine) }
                return true
            }
            // Lid closed: there's no built-in panel to follow, so drive the
            // monitor directly.
            guard let monitorKey = DisplayInputEngine.monitors.first(where: \.reachable)?.key else { return false }
            if isDown { adjustDDCBrightness(monitorKey: monitorKey, up: up, fine: fine) }
            return true

        case AuxKey.play, AuxKey.next, AuxKey.previous:
            // Tell the music monitor regardless of who ends up handling the key:
            // a transport press means playback state is about to change, and
            // reading immediately is what keeps the indicator feeling instant
            // when the poller has backed off. Never changes the return value.
            if isDown && !isRepeat {
                onTransportKey?()
                switch keyCode {
                case AuxKey.play: onTransportAction?(.playPause)
                case AuxKey.next: onTransportAction?(.next)
                default:          onTransportAction?(.previous)
                }
            }
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
        if let monitorKey = ddcMonitorKey(for: device) {
            adjustDDCVolume(monitorKey: monitorKey, up: up, fine: fine)
            return
        }
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
        shown(device)
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
    func toggleMute() {
        guard let device = defaultOutputDevice() else { return }
        if let monitorKey = ddcMonitorKey(for: device) {
            toggleDDCMute(monitorKey: monitorKey)
            return
        }
        let newMuted = !isMuted(device)
        setMuted(device, newMuted)
        shown(device)
        onChange?(.volume, CGFloat(volume(device) ?? 0), newMuted, audioOutputKind(for: device))
    }

    // MARK: - Volume (DDC, monitor speakers)
    //
    // HDMI/DisplayPort outputs expose no CoreAudio volume, which is why macOS
    // greys the keys out for them. When the monitor answers DDC, the keys set
    // its speaker level over VCP 0x62 instead. The level is cached here so the
    // HUD answers at key speed; the panel is read once, on the first press.
    // The MP341CQ has no working DDC mute (VCP 0x8D reports unsupported), so
    // mute parks the level at 0 and remembers what to restore.
    //
    // The bar is an equal-loudness scale, the panel's 0…100 is not: monitors
    // commonly treat it as linear gain (the MP341CQ sounds that way), where the
    // whole top half is only ~6 dB and the middle of a linear bar barely changes
    // anything. Levels go
    // through an audio taper instead, so every key step is about the same
    // audible change (30 dB over 16 steps ≈ 1.9 dB each; panel values
    // 100, 81, 65, 52, 42, 34, 27, 22, 18, 14, 12, 9, 7, 6, 5, 4, then 0).

    /// dB spanned by the bar, from its first step to full.
    private static let ddcTaperRange = 30.0

    /// Bar position (0…1) → fraction of the panel's own volume maximum.
    private static func panelLevel(forBar bar: Float) -> Double {
        bar <= 0 ? 0 : pow(10, (Double(bar) - 1) * ddcTaperRange / 20)
    }

    /// Fraction of the panel's maximum → bar position (0…1).
    private static func bar(forPanelLevel level: Double) -> Float {
        level <= 0 ? 0 : Float(max(0, 1 + 20 * log10(level) / ddcTaperRange))
    }

    /// Last known bar position per monitor key, 0…1 on the 1/16 (or 1/64) key grid.
    private var ddcVolume: [String: Float] = [:]
    /// The level to restore on unmute, per monitor key; present while muted.
    private var ddcMutedLevel: [String: Float] = [:]
    /// Monitors with a first read in flight, so a held key doesn't queue more.
    private var ddcReading: Set<String> = []

    /// The DDC monitor behind `device`, when `device` is monitor audio that
    /// CoreAudio cannot turn up or down itself.
    private func ddcMonitorKey(for device: AudioDeviceID) -> String? {
        guard isDisplayAudio(device), !hasSettableVolume(device) else { return nil }
        return DisplayInputEngine.monitorKey(named: audioDeviceName(device))
    }

    private func isDisplayAudio(_ device: AudioDeviceID) -> Bool {
        let transport = audioDeviceTransportType(device)
        return transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort
    }

    private func hasSettableVolume(_ device: AudioDeviceID) -> Bool {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = volumeAddress(element: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &addr),
               AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    @MainActor
    private func adjustDDCVolume(monitorKey: String, up: Bool, fine: Bool) {
        // A wedged link takes no commands until the adapter is replugged. Say so
        // with a dimmed bar rather than pretending the level moved.
        guard !DisplayInputEngine.isStalled else {
            onChange?(.volume, CGFloat(ddcVolume[monitorKey] ?? 0), true, .displaySpeaker)
            return
        }
        guard let current = ddcVolume[monitorKey] else {
            // First press since launch: learn the panel's level, then apply
            // this press to it.
            guard !ddcReading.contains(monitorKey) else { return }
            ddcReading.insert(monitorKey)
            DisplayInputEngine.readLevel(.volume, monitorKey: monitorKey) { [weak self] level in
                guard let self else { return }
                self.ddcReading.remove(monitorKey)
                guard let level else {
                    self.onChange?(.volume, 0, true, .displaySpeaker)
                    return
                }
                self.ddcVolume[monitorKey] = Self.bar(forPanelLevel: level)
                self.adjustDDCVolume(monitorKey: monitorKey, up: up, fine: fine)
            }
            return
        }

        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        let grid: Float = fine ? 64.0 : 16.0
        // Raising volume while muted unmutes from the remembered level.
        var base = current
        if let restore = ddcMutedLevel.removeValue(forKey: monitorKey) {
            base = up ? restore : 0
        }
        var next = up ? base + step : base - step
        next = max(0, min(1, (next * grid).rounded() / grid))
        ddcVolume[monitorKey] = next
        DisplayInputEngine.setLevel(.volume, monitorKey: monitorKey, to: Self.panelLevel(forBar: next))

        playVolumeFeedback()
        onChange?(.volume, CGFloat(next), false, .displaySpeaker)
    }

    @MainActor
    private func toggleDDCMute(monitorKey: String) {
        guard let current = ddcVolume[monitorKey] else {
            guard !ddcReading.contains(monitorKey) else { return }
            ddcReading.insert(monitorKey)
            DisplayInputEngine.readLevel(.volume, monitorKey: monitorKey) { [weak self] level in
                guard let self else { return }
                self.ddcReading.remove(monitorKey)
                guard let level else { return }
                self.ddcVolume[monitorKey] = Self.bar(forPanelLevel: level)
                self.toggleDDCMute(monitorKey: monitorKey)
            }
            return
        }

        if let restore = ddcMutedLevel.removeValue(forKey: monitorKey) {
            ddcVolume[monitorKey] = restore
            DisplayInputEngine.setLevel(.volume, monitorKey: monitorKey, to: Self.panelLevel(forBar: restore))
            onChange?(.volume, CGFloat(restore), false, .displaySpeaker)
        } else {
            ddcMutedLevel[monitorKey] = current
            DisplayInputEngine.setLevel(.volume, monitorKey: monitorKey, to: 0)
            onChange?(.volume, CGFloat(current), true, .displaySpeaker)
        }
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

    func audioOutputKind(for device: AudioDeviceID) -> AudioOutputKind {
        if isDisplayAudio(device) { return .displaySpeaker }

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

        // Same name over USB-C audio and Bluetooth.
        if searchable.contains("nothing headphone") {
            return .nothingHeadphone
        }

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

    // MARK: - Brightness (DDC, lid closed)
    //
    // With the built-in panel on, external monitors follow it instead (see
    // ExternalBrightnessSync). Linear, unlike the volume bar: the panel's
    // minimum backlight is well above black, so its 0…100 already feels evenly
    // spaced, and the bar then matches the number in the monitor's own menu.
    // Cached like the volume, read once on the first press.

    /// Last known brightness per monitor key, 0…1 of the panel's maximum.
    private var ddcBrightness: [String: Float] = [:]
    private var ddcBrightnessReading: Set<String> = []

    @MainActor
    private func adjustDDCBrightness(monitorKey: String, up: Bool, fine: Bool) {
        // A wedged link takes no commands until the adapter is replugged; an
        // empty bar says so rather than pretending the level moved.
        guard !DisplayInputEngine.isStalled else {
            onChange?(.brightness, 0, false, nil)
            return
        }
        guard let current = ddcBrightness[monitorKey] else {
            guard !ddcBrightnessReading.contains(monitorKey) else { return }
            ddcBrightnessReading.insert(monitorKey)
            DisplayInputEngine.readLevel(.brightness, monitorKey: monitorKey) { [weak self] level in
                guard let self else { return }
                self.ddcBrightnessReading.remove(monitorKey)
                guard let level else {
                    self.onChange?(.brightness, 0, false, nil)
                    return
                }
                self.ddcBrightness[monitorKey] = Float(level)
                self.adjustDDCBrightness(monitorKey: monitorKey, up: up, fine: fine)
            }
            return
        }

        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        let grid: Float = fine ? 64.0 : 16.0
        var next = up ? current + step : current - step
        next = max(0, min(1, (next * grid).rounded() / grid))
        ddcBrightness[monitorKey] = next
        DisplayInputEngine.setLevel(.brightness, monitorKey: monitorKey, to: Double(next))
        onChange?(.brightness, CGFloat(next), false, nil)
    }

    // MARK: - Volume changed elsewhere
    //
    // The keys are only one way the level moves: a headset's own buttons or an
    // app move it too, and the HUD shows those as well. CoreAudio reports every
    // change to the default output; whatever the HUD hasn't already shown (a key
    // press here is shown, then echoed) is shown. A slider moved with the pointer
    // (Control Center, the Sound menu, Settings) is already on screen and isn't.
    // A monitor's DDC volume has no such report, and is never polled.

    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var listenedDevice: AudioDeviceID?
    private var lastShown: (device: AudioDeviceID, value: Float?, muted: Bool)?
    /// A newly chosen output reports its level as it arrives; not a change to show.
    private var quietUntil: CFAbsoluteTime = 0
    private var pendingOutside: DispatchWorkItem?

    @MainActor
    private func startOutsideVolume() {
        guard defaultOutputListener == nil else { return }
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultOutput() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        defaultOutputListener = block
        followDefaultOutput()
    }

    @MainActor
    private func stopOutsideVolume() {
        if let block = defaultOutputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        defaultOutputListener = nil
        unlistenVolume()
        pendingOutside?.cancel()
        pendingOutside = nil
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The output's level (whole and per front channel) and its mute.
    private func levelAddresses() -> [AudioObjectPropertyAddress] {
        [volumeAddress(element: kAudioObjectPropertyElementMain), volumeAddress(element: 1),
         volumeAddress(element: 2), muteAddress()]
    }

    @MainActor
    private func followDefaultOutput() {
        let device = defaultOutputDevice()
        guard device != listenedDevice else { return }
        unlistenVolume()
        listenedDevice = device
        quietUntil = CFAbsoluteTimeGetCurrent() + 1
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outsideVolumeChanged() }
        }
        for var address in levelAddresses() where AudioObjectHasProperty(device, &address) {
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        }
        volumeListener = block
        shown(device)
    }

    private func unlistenVolume() {
        if let device = listenedDevice, let block = volumeListener {
            for var address in levelAddresses() where AudioObjectHasProperty(device, &address) {
                AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            }
        }
        volumeListener = nil
        listenedDevice = nil
    }

    /// Left and right report one after the other: one look once they're both in.
    @MainActor
    private func outsideVolumeChanged() {
        pendingOutside?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showOutsideVolume() }
        }
        pendingOutside = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    @MainActor
    private func showOutsideVolume() {
        pendingOutside = nil
        guard let device = listenedDevice, device == defaultOutputDevice() else { return }
        let value = volume(device), muted = isMuted(device)
        let last = lastShown
        shown(device)
        guard CFAbsoluteTimeGetCurrent() >= quietUntil, !Self.pointerJustUsed,
              settings.systemHUDEnabled, settings.systemHUDVolume, let value else { return }
        if let last, last.device == device, last.muted == muted,
           let before = last.value, abs(before - value) < 0.002 { return }
        onChange?(.volume, CGFloat(value), muted, audioOutputKind(for: device))
    }

    /// A button is down, or went up a moment ago: the change came from a slider.
    private static var pointerJustUsed: Bool {
        guard NSEvent.pressedMouseButtons == 0 else { return true }
        let since: (CGEventType) -> Double = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return min(since(.leftMouseUp), since(.leftMouseDragged), since(.leftMouseDown)) < 0.4
    }

    /// What the HUD now shows for `device`, so CoreAudio's echo of it isn't shown again.
    private func shown(_ device: AudioDeviceID) {
        lastShown = (device, volume(device), isMuted(device))
    }

    // MARK: - Notch HUD controls
    //
    // The notch HUD's bars can be dragged and its outputs picked. These set an
    // absolute level, so a monitor's DDC volume needs no read first; its writes
    // still collapse in DisplayInputEngine.setLevel however fast a drag runs.

    /// The default output as the HUD shows it. `value` is nil for a monitor
    /// whose level hasn't been read yet (only the volume keys read it), or an
    /// output with no volume at all.
    @MainActor
    func outputState() -> (name: String, value: CGFloat?, muted: Bool, kind: AudioOutputKind)? {
        guard let device = defaultOutputDevice() else { return nil }
        let name = audioDeviceName(device)
        if let key = ddcMonitorKey(for: device) {
            return (name, ddcVolume[key].map { CGFloat($0) }, ddcMutedLevel[key] != nil, .displaySpeaker)
        }
        let value = hasSettableVolume(device) ? volume(device).map { CGFloat($0) } : nil
        return (name, value, isMuted(device), audioOutputKind(for: device))
    }

    /// Sets the default output to `value` (0…1); returns what it now reads.
    /// `final` marks the end of a drag, which ticks like a key press.
    @MainActor
    @discardableResult
    func setOutputVolume(_ value: CGFloat, final: Bool) -> (value: CGFloat, muted: Bool)? {
        guard let device = defaultOutputDevice() else { return nil }
        let v = Float(max(0, min(1, value)))
        if let key = ddcMonitorKey(for: device) {
            guard !DisplayInputEngine.isStalled else { return nil }
            ddcMutedLevel.removeValue(forKey: key)
            ddcVolume[key] = v
            DisplayInputEngine.setLevel(.volume, monitorKey: key, to: Self.panelLevel(forBar: v))
            if final { playVolumeFeedback() }
            return (CGFloat(v), false)
        }
        guard hasSettableVolume(device) else { return nil }
        if v > 0, isMuted(device) { setMuted(device, false) }
        setVolume(device, v)
        shown(device)
        if final { playVolumeFeedback() }
        return (CGFloat(volume(device) ?? v), isMuted(device))
    }

    /// The level the brightness keys drive: the built-in panel, or with the
    /// lid closed the monitor (nil until a key has read it).
    @MainActor
    func brightnessLevel() -> CGFloat? {
        if let display = builtinDisplay() {
            return DisplayServicesBridge.shared.getBrightness(display).map { CGFloat($0) }
        }
        guard let key = DisplayInputEngine.monitors.first(where: \.reachable)?.key else { return nil }
        return ddcBrightness[key].map { CGFloat($0) }
    }

    /// Names the same display the brightness keys drive.
    @MainActor
    var brightnessDisplayName: String {
        if builtinDisplay() != nil { return "\(MacModel.name) Display" }
        return DisplayInputEngine.monitors.first(where: \.reachable)?.name ?? "Display"
    }

    /// Sets what the brightness keys drive to `value` (0…1); returns what it now reads.
    @MainActor
    @discardableResult
    func setBrightnessLevel(_ value: CGFloat) -> CGFloat? {
        let v = Float(max(0, min(1, value)))
        if let display = builtinDisplay() {
            DisplayServicesBridge.shared.setBrightness(display, v)
            return CGFloat(DisplayServicesBridge.shared.getBrightness(display) ?? v)
        }
        guard !DisplayInputEngine.isStalled,
              let key = DisplayInputEngine.monitors.first(where: \.reachable)?.key else { return nil }
        ddcBrightness[key] = v
        DisplayInputEngine.setLevel(.brightness, monitorKey: key, to: Double(v))
        return CGFloat(v)
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
