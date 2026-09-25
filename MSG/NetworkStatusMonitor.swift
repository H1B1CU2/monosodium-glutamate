import CoreWLAN
import Foundation

/// Wi-Fi state for the control bar's Duo indicator: power, connection, and whether
/// the link is an iPhone's Personal Hotspot.
///
/// Push-driven by CoreWLAN events, so a bar redraw reads a cached value
/// instead of making a CoreWLAN round trip every frame, and nothing polls
/// while the network sits still.
///
/// No `NWPathMonitor`: the build searches PrivateFrameworks, where a private
/// `Network` framework shadows the public one.
final class NetworkStatusMonitor: NSObject, CWEventDelegate {
    static let shared = NetworkStatusMonitor()

    struct Status: Equatable {
        var powerOn = true
        var connected = false
        /// Personal Hotspot from an iPhone, or another tethered phone.
        var hotspot = false
    }

    private(set) var status = Status()
    /// Main thread, only when something the indicator draws has changed.
    var onChange: (() -> Void)?

    private let client = CWWiFiClient.shared()
    private(set) var isRunning = false

    private static let events: [CWEventType] = [.powerDidChange, .linkDidChange, .ssidDidChange]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        client.delegate = self
        for event in Self.events { try? client.startMonitoringEvent(with: event) }
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    // MARK: CWEventDelegate — called on CoreWLAN's queue

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { refreshOnMain() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        refreshOnMain()
        // DHCP hands out the address a moment after the link comes up, and the
        // hotspot check reads that address; look again once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { refreshOnMain() }

    private func refreshOnMain() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        var next = Status()
        if let interface = client.interface() {
            next.powerOn = interface.powerOn()
            // Associated networks report a channel; no SSID read, so no
            // Location Services prompt.
            next.connected = next.powerOn && interface.wlanChannel() != nil
            if next.connected {
                next.hotspot = Self.isPersonalHotspotAddress(interfaceName: interface.interfaceName)
            }
        } else {
            next.powerOn = false
        }
        guard next != status else { return }
        status = next
        onChange?()
    }

    /// iPhone Personal Hotspot always hands out addresses in 172.20.10.0/28,
    /// whatever the hotspot is named — no SSID read, no Location prompt.
    private static func isPersonalHotspotAddress(interfaceName: String?) -> Bool {
        guard let interfaceName else { return false }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == interfaceName else { continue }
            let ipv4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // 172.20.10.0/28
            if ipv4 & 0xFFFF_FFF0 == 0xAC14_0A00 { return true }
        }
        return false
    }
}
