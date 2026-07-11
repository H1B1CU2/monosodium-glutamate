import CoreBluetooth

/// Identifies the real hardware model of a connected Apple Bluetooth headset
/// via its "Proximity Pairing" BLE broadcast, independent of the Bluetooth
/// device's user-editable name (which `SystemHUDMonitor`'s name-based
/// heuristic relies on and which breaks the moment a device is renamed).
///
/// Apple's audio accessories continuously broadcast an unencrypted
/// manufacturer-data message (company ID 0x004C, message type 0x07)
/// whenever powered on. Byte layout and device-model IDs cross-checked
/// against furiousMAC's continuity protocol docs, hexway's apple_bleee
/// parser, and the BLE-DB dataset:
///
///   [0-1] company ID (0x004C, little-endian) [2] type (0x07) [3] length
///   [4] prefix (0x01) [5-6] device model (big-endian UInt16) [7...] status/battery/encrypted
final class AirPodsBLEDetector: NSObject {
    static let shared = AirPodsBLEDetector()

    private struct Candidate {
        let kind: AudioOutputKind
        let rssi: Int
        let seenAt: Date
    }

    /// A candidate is only trusted for this long after last being seen.
    private static let staleAfter: TimeInterval = 8
    /// When a different-model candidate is still within this window, a
    /// weaker new reading doesn't replace it (avoids flapping between two
    /// nearby Apple headsets, e.g. yours and a neighbor's).
    private static let recentWindow: TimeInterval = 4

    /// Proximity Pairing device-model IDs, mapped to the closest icon this
    /// app already draws. AirPods Max isn't a dedicated icon kind here (no
    /// over-ear glyph in the family) so it maps to the closer `.headphones`
    /// silhouette rather than the earbud-shaped `.airPods` one.
    private static let modelKinds: [UInt16: AudioOutputKind] = [
        0x0E20: .airPodsPro, // AirPods Pro (1st gen)
        0x1420: .airPodsPro, // AirPods Pro (2nd gen, Lightning)
        0x2420: .airPodsPro, // AirPods Pro (2nd gen, USB-C) — confirmed via live scan on this device
        0x0220: .airPods,    // AirPods (1st gen)
        0x0F20: .airPods,    // AirPods (2nd gen)
        0x1320: .airPods,    // AirPods (3rd gen)
        0x1920: .airPods,    // AirPods (4th gen)
        0x1B20: .airPods,    // AirPods (4th gen, ANC) — stemless like regular AirPods, not Pro-shaped
        0x0A20: .headphones, // AirPods Max (Lightning)
        0x1F20: .headphones, // AirPods Max (USB-C)
    ]

    private var central: CBCentralManager?
    private var best: Candidate?
    private var active = false

    private override init() { super.init() }

    func start() {
        guard !active else { return }
        active = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                        options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            beginScan()
        }
    }

    func stop() {
        active = false
        best = nil
        if central?.isScanning == true { central?.stopScan() }
    }

    /// Best current guess for the connected Bluetooth output device's real
    /// model, or nil if nothing fresh enough has been seen.
    func currentKind() -> AudioOutputKind? {
        guard let best, Date().timeIntervalSince(best.seenAt) < Self.staleAfter else { return nil }
        return best.kind
    }

    private func beginScan() {
        guard active, central?.state == .poweredOn, central?.isScanning != true else { return }
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

extension AirPodsBLEDetector: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .unauthorized:
            NSLog("[MSG] AirPodsBLEDetector: Bluetooth permission denied — device-specific icons will use the name heuristic only.")
            best = nil
        default:
            best = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 7 else { return }
        let companyID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        guard companyID == 0x004C, data[2] == 0x07 else { return } // Apple, Proximity Pairing
        let model = (UInt16(data[5]) << 8) | UInt16(data[6])
        guard let kind = Self.modelKinds[model] else { return }

        let rssi = RSSI.intValue
        guard rssi != 127 else { return } // sentinel for "unavailable"

        let now = Date()
        if let existing = best, kind != existing.kind,
           now.timeIntervalSince(existing.seenAt) < Self.recentWindow, rssi <= existing.rssi {
            return
        }
        best = Candidate(kind: kind, rssi: rssi, seenAt: now)
    }
}
