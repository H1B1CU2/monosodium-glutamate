import AppKit
import CoreAudio

enum NotchAudioDeviceIcon {
    static func symbolName(for name: String) -> String? {
        let name = name.lowercased()
        if name.contains("nothing") && (name.contains("headphone") || name.contains("headset")) { return "headphones" }
        if name.contains("samsung") || name.contains("galaxy") || name.contains("iphone") { return "iphone.gen3" }
        if name.contains("macbook") { return "macbook.gen2" }
        return nil
    }
}
import Foundation

/// The system's currently available audio routes. Reading is safe for
/// the strip's status polling; changing a default route happens only on a key
/// press or a device selection in its temporary chooser.
enum AudioDeviceRouting {
    enum Direction: Equatable {
        case input, output

        var scope: AudioObjectPropertyScope {
            self == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        }

        var defaultSelector: AudioObjectPropertySelector {
            self == .input ? kAudioHardwarePropertyDefaultInputDevice
                           : kAudioHardwarePropertyDefaultOutputDevice
        }
    }

    /// AudioSpectrumTap's aggregate device. Private, so other apps never see
    /// it, but MSG does: its own lists leave it out.
    static let visualizerTapUID = "com.msg.visualizer-tap"

    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    }

    struct Snapshot: Equatable {
        let devices: [Device]
        let selectedUID: String?

        var selected: Device? { devices.first { $0.uid == selectedUID } }
    }

    struct Page {
        struct Item: Equatable {
            let device: Device?
            let keys: ClosedRange<Int>
            var isMore: Bool { device == nil }
        }

        let items: [Item]
        let devicesByKey: [Int: Device]
        let moreKey: Int?
        let number: Int
        let count: Int
    }

    /// Whether a device name is too wide to fit comfortably on 1 keycap (~62 pt usable width, ~10 characters).
    static func needsTwoKeys(_ name: String) -> Bool {
        if name.count > 10 { return true }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        return textWidth > 62
    }

    /// Packs devices into pages, giving devices that need 2 keys 2 adjacent function keys
    /// when available, and 1 key for short names. When items overflow, the last available
    /// slot is reserved for "More ›" pagination.
    static func buildPages(_ devices: [Device], reservedKey: Int?) -> [Page] {
        let slots = (1...12).filter { $0 != reservedKey }
        guard !slots.isEmpty else {
            return [Page(items: [], devicesByKey: [:], moreKey: nil, number: 0, count: 1)]
        }
        guard !devices.isEmpty else {
            return [Page(items: [], devicesByKey: [:], moreKey: nil, number: 0, count: 1)]
        }

        func pack(from deviceIndex: Int, into usableSlots: [Int]) -> (items: [Page.Item], map: [Int: Device], consumed: Int) {
            var items: [Page.Item] = []
            var map: [Int: Device] = [:]
            var slotIdx = 0
            var devIdx = deviceIndex

            while devIdx < devices.count && slotIdx < usableSlots.count {
                let dev = devices[devIdx]
                let wantsTwo = needsTwoKeys(dev.name)
                let canTakeTwo = wantsTwo
                    && (slotIdx + 1 < usableSlots.count)
                    && (usableSlots[slotIdx + 1] == usableSlots[slotIdx] + 1)

                if wantsTwo && canTakeTwo {
                    let k1 = usableSlots[slotIdx]
                    let k2 = usableSlots[slotIdx + 1]
                    items.append(Page.Item(device: dev, keys: k1...k2))
                    map[k1] = dev
                    map[k2] = dev
                    slotIdx += 2
                    devIdx += 1
                } else if !wantsTwo {
                    let k = usableSlots[slotIdx]
                    items.append(Page.Item(device: dev, keys: k...k))
                    map[k] = dev
                    slotIdx += 1
                    devIdx += 1
                } else {
                    if items.isEmpty {
                        let k = usableSlots[slotIdx]
                        items.append(Page.Item(device: dev, keys: k...k))
                        map[k] = dev
                        slotIdx += 1
                        devIdx += 1
                    } else {
                        break
                    }
                }
            }
            return (items, map, devIdx - deviceIndex)
        }

        let singleTry = pack(from: 0, into: slots)
        if singleTry.consumed == devices.count {
            return [Page(items: singleTry.items,
                         devicesByKey: singleTry.map,
                         moreKey: nil,
                         number: 0,
                         count: 1)]
        }

        let moreSlot = slots.last!
        let usableSlots = Array(slots.dropLast())
        guard !usableSlots.isEmpty else {
            let pages = devices.enumerated().map { (i, dev) in
                Page(items: [Page.Item(device: dev, keys: moreSlot...moreSlot)],
                     devicesByKey: [moreSlot: dev],
                     moreKey: moreSlot,
                     number: i,
                     count: devices.count)
            }
            return pages
        }

        var pages: [Page] = []
        var devIdx = 0

        while devIdx < devices.count {
            let pagePack = pack(from: devIdx, into: usableSlots)
            guard pagePack.consumed > 0 else {
                let dev = devices[devIdx]
                let k = usableSlots[0]
                var items = [Page.Item(device: dev, keys: k...k)]
                items.append(Page.Item(device: nil, keys: moreSlot...moreSlot))
                pages.append(Page(items: items,
                                  devicesByKey: [k: dev],
                                  moreKey: moreSlot,
                                  number: pages.count,
                                  count: 0))
                devIdx += 1
                continue
            }

            var items = pagePack.items
            items.append(Page.Item(device: nil, keys: moreSlot...moreSlot))
            pages.append(Page(items: items,
                              devicesByKey: pagePack.map,
                              moreKey: moreSlot,
                              number: pages.count,
                              count: 0))
            devIdx += pagePack.consumed
        }

        let totalPages = pages.count
        return pages.enumerated().map { (i, p) in
            Page(items: p.items,
                 devicesByKey: p.devicesByKey,
                 moreKey: p.moreKey,
                 number: i,
                 count: totalPages)
        }
    }

    /// Function keys assigned to a chooser; F12 (or whichever F key owns the
    /// modifier) stays untouched. When routes overflow, the last slot pages.
    static func page(_ devices: [Device], reservedKey: Int?, number: Int) -> Page {
        let pages = buildPages(devices, reservedKey: reservedKey)
        guard !pages.isEmpty else {
            return Page(items: [], devicesByKey: [:], moreKey: nil, number: 0, count: 1)
        }
        let index = ((number % pages.count) + pages.count) % pages.count
        return pages[index]
    }

    static func snapshot(_ direction: Direction) -> Snapshot {
        let devices = availableDevices(direction)
        let selectedUID = defaultDevice(direction).flatMap(deviceUID)
        return Snapshot(devices: devices, selectedUID: selectedUID)
    }

    @discardableResult
    static func select(_ direction: Direction, uid: String) -> Bool {
        // Re-enumerate immediately before the write: a headset or display may
        // have disappeared while its chooser was visible.
        guard let target = availableDevices(direction).first(where: { $0.uid == uid }) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: direction.defaultSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectIsPropertySettable(system, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var id = target.id
        return AudioObjectSetPropertyData(system, &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func availableDevices(_ direction: Direction) -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr,
              byteCount >= MemoryLayout<AudioDeviceID>.size else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &ids) == noErr else { return [] }

        var seen = Set<String>()
        return ids.compactMap { id -> Device? in
            guard deviceIsAlive(id), hasStream(id, scope: direction.scope),
                  let uid = deviceUID(id), !uid.isEmpty, uid != visualizerTapUID,
                  seen.insert(uid).inserted else { return nil }
            let transport = deviceTransport(id)
            let name = stringProperty(kAudioObjectPropertyName, device: id) ?? uid
            return Device(id: id, uid: uid, name: name, transport: transport)
        }.sorted { lhs, rhs in
            let a = rank(lhs.transport), b = rank(rhs.transport)
            if a != b { return a < b }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.uid < rhs.uid : comparison == .orderedAscending
        }
    }

    private static func rank(_ transport: UInt32) -> Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return 1
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 2
        case kAudioDeviceTransportTypeUSB: return 3
        case kAudioDeviceTransportTypeAirPlay: return 4
        default: return 5
        }
    }

    private static func defaultDevice(_ direction: Direction) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: direction.defaultSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, device: id)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var string: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &string) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? string as String? : nil
    }

    private static func deviceTransport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return true }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func hasStream(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioStreamID>.size
    }
}
