import AppKit
import CoreLocation
import CoreWLAN
import SwiftUI

// MARK: - Layout

/// Geometry of MSG's Wi-Fi menu, which hangs from the control bar's Duo
/// indicator. Rows carry the asserted radius; the panel's follows from it.
@available(macOS 14.0, *)
enum WiFiMenuLayout {
    static let width: CGFloat = 300
    static let rowRadius: CGFloat = 10
    static let padding: CGFloat = 6
    /// Concentric with the rows it holds.
    static var panelRadius: CGFloat { rowRadius + padding }
    static let rowHeight: CGFloat = 32
    static let maxOtherNetworks = 10
}

// MARK: - Model

@available(macOS 14.0, *)
struct WiFiMenuNetwork: Identifiable, Equatable {
    let ssid: String
    let rssi: Int
    let secured: Bool
    let known: Bool
    var id: String { ssid }

    var bars: Int {
        switch rssi {
        case (-60)...: return 3
        case (-72)...: return 2
        default: return 1
        }
    }
}

@available(macOS 14.0, *)
private final class WiFiMenuModel: ObservableObject {
    @Published var powerOn = true
    @Published var current: WiFiMenuNetwork?
    @Published var currentIsHotspot = false
    @Published var others: [WiFiMenuNetwork] = []
    @Published var scanning = false
    /// Network names need Location access; without it the list can't be shown.
    @Published var locationAllowed = true
    @Published var joining: String?
    @Published var passwordFor: String?
    @Published var password = ""
    @Published var failed: String?
    @Published var powerError = false

    var onTogglePower: (Bool) -> Void = { _ in }
    var onSelect: (WiFiMenuNetwork) -> Void = { _ in }
    var onJoinWithPassword: (WiFiMenuNetwork, String) -> Void = { _, _ in }
    var onAllowLocation: () -> Void = {}
    var onOpenSettings: () -> Void = {}
}

// MARK: - View

@available(macOS 14.0, *)
private struct WiFiMenuView: View {
    @ObservedObject var model: WiFiMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if model.powerOn {
                separator
                if !model.locationAllowed {
                    locationRow
                } else {
                    if let current = model.current {
                        sectionTitle("Connected")
                        networkRow(current, isCurrent: true)
                    }
                    sectionTitle(model.scanning ? "Other Networks  ·  Scanning…" : "Other Networks")
                    if model.others.isEmpty && !model.scanning {
                        Text("No networks found")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: WiFiMenuLayout.rowHeight)
                    }
                    ForEach(model.others) { network in
                        networkRow(network, isCurrent: false)
                    }
                }
            }
            separator
            MenuRow(action: model.onOpenSettings) {
                Text("Wi-Fi Settings…").font(.system(size: 13))
                Spacer(minLength: 0)
            }
        }
        .padding(WiFiMenuLayout.padding)
        .frame(width: WiFiMenuLayout.width, alignment: .topLeading)
        .modifier(PreviewPanelChrome(radius: WiFiMenuLayout.panelRadius))
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.16), value: model.others)
        .animation(.easeOut(duration: 0.16), value: model.passwordFor)
        .animation(.easeOut(duration: 0.16), value: model.powerOn)
    }

    private var header: some View {
        HStack {
            Text("Wi-Fi").font(.system(size: 13, weight: .semibold))
            if model.powerError {
                Text("Needs administrator approval")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { model.powerOn }, set: { model.onTogglePower($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(height: WiFiMenuLayout.rowHeight)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 1)
    }

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS only shows Wi-Fi network names to apps with Location access.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Location Access", action: model.onAllowLocation)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func networkRow(_ network: WiFiMenuNetwork, isCurrent: Bool) -> some View {
        MenuRow(action: { if !isCurrent { model.onSelect(network) } }) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(width: 24, height: 24)
                Image(systemName: isCurrent && model.currentIsHotspot ? "personalhotspot" : "wifi",
                      variableValue: Double(network.bars) / 3)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(network.ssid)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if model.failed == network.ssid {
                    Text("Couldn't join this network")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            if model.joining == network.ssid {
                ProgressView().controlSize(.mini)
            } else if network.secured {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        if model.passwordFor == network.ssid {
            HStack(spacing: 6) {
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { model.onJoinWithPassword(network, model.password) }
                Button("Join") { model.onJoinWithPassword(network, model.password) }
                    .controlSize(.small)
                    .disabled(model.password.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.opacity)
        }
    }
}

/// A menu row: full width, highlighted under the pointer like a native menu.
@available(macOS 14.0, *)
private struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        // A plain Button, not a tap gesture: buttons take the first click in a
        // panel that isn't key, as the control bar previews' buttons do.
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8)
                .frame(height: WiFiMenuLayout.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: WiFiMenuLayout.rowRadius, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Controller

/// MSG's Wi-Fi menu, anchored on the control bar's Duo indicator.
///
/// macOS offers no way to open its own Wi-Fi menu at another position, and
/// none at all once the Wi-Fi icon is removed from the menu bar, so MSG draws
/// its own: Wi-Fi power, the connected network (marked when it is a Personal
/// Hotspot), nearby networks to join, and a way into Wi-Fi Settings.
@available(macOS 14.0, *)
final class WiFiMenuController: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiMenuController()

    private let model = WiFiMenuModel()
    private var panel: WiFiMenuPanel?
    private var hosting: NSHostingView<WiFiMenuView>?
    private var monitors: [Any] = []
    private var anchor: CGRect = .zero
    private var bar: CGRect = .zero
    private var scanGeneration = 0
    private let queue = DispatchQueue(label: "msg.wifi-menu", qos: .userInitiated)
    private lazy var location = CLLocationManager()
    private lazy var measurer = NSHostingController(rootView: WiFiMenuView(model: model))

    var isVisible: Bool { panel?.isVisible == true }

    private override init() { super.init() }

    // MARK: Showing

    /// Opens the menu under `icon` (screen coordinates), or closes it if open.
    func toggle(below icon: CGRect, bar: CGRect) {
        if isVisible {
            dismiss()
            return
        }
        anchor = icon
        self.bar = bar
        wire()
        location.delegate = self
        updateLocationAccess()
        model.failed = nil
        model.passwordFor = nil
        model.password = ""
        reload(scanning: true)
        present()
    }

    func dismiss() {
        scanGeneration &+= 1
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
    }

    private func present() {
        buildPanelIfNeeded()
        guard let panel else { return }
        resize()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        installMonitors()
    }

    /// Hangs from the bar under the icon, left edges aligned like a menu,
    /// kept on the icon's screen.
    private func resize() {
        guard let panel else { return }
        // Measured through a hosting controller: the panel's own hosting view
        // has sizing turned off (so it never pushes a size onto the panel),
        // and with that off its `fittingSize` is zero — the menu opened at no
        // height at all.
        let fitted = measurer.sizeThatFits(in: CGSize(width: WiFiMenuLayout.width,
                                                      height: CGFloat.greatestFiniteMagnitude))
        let size = NSSize(width: WiFiMenuLayout.width, height: ceil(fitted.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(bar) } ?? NSScreen.main ?? NSScreen.screens[0]
        let inset = TilingBarPreviewLayout.screenInset
        let x = min(max(anchor.minX - WiFiMenuLayout.padding, screen.frame.minX + inset),
                    screen.frame.maxX - size.width - inset)
        let y = bar.minY - TilingBarPreviewLayout.gapBelowBar - size.height
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Actions

    private func wire() {
        model.onTogglePower = { [weak self] on in self?.setPower(on) }
        model.onSelect = { [weak self] network in self?.select(network) }
        model.onJoinWithPassword = { [weak self] network, password in
            self?.join(network, password: password)
        }
        model.onAllowLocation = { [weak self] in self?.requestLocation() }
        model.onOpenSettings = { [weak self] in
            self?.dismiss()
            if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func setPower(_ on: Bool) {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        do {
            try interface.setPower(on)
            model.powerError = false
            model.powerOn = on
            reload(scanning: on)
        } catch {
            model.powerError = true
        }
        resizeSoon()
    }

    private func select(_ network: WiFiMenuNetwork) {
        model.failed = nil
        if network.secured && !network.known {
            model.passwordFor = network.ssid
            model.password = ""
            panel?.makeKey()
            resizeSoon()
            return
        }
        join(network, password: nil)
    }

    /// Open and saved networks join directly: `networksetup` reads the saved
    /// password from the keychain the way the system menu does. A new secured
    /// network joins with the password typed into the row.
    private func join(_ network: WiFiMenuNetwork, password: String?) {
        guard let interface = CWWiFiClient.shared().interface(), let name = interface.interfaceName else { return }
        model.joining = network.ssid
        model.passwordFor = nil
        let ssid = network.ssid
        let secured = network.secured
        queue.async { [weak self] in
            var joined = false
            if let password, !password.isEmpty {
                if let target = (try? interface.scanForNetworks(withName: ssid))?.first {
                    joined = (try? interface.associate(to: target, password: password)) != nil
                }
            } else if !secured, let target = (try? interface.scanForNetworks(withName: ssid))?.first {
                joined = (try? interface.associate(to: target, password: nil)) != nil
            } else {
                joined = Self.networksetupJoin(interface: name, ssid: ssid)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.joining = nil
                if joined {
                    self.dismiss()
                } else {
                    self.model.failed = ssid
                    if secured { self.model.passwordFor = ssid }
                    self.resizeSoon()
                }
            }
        }
    }

    private static func networksetupJoin(interface: String, ssid: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-setairportnetwork", interface, ssid]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        // networksetup exits 0 even on failure; any output is an error message.
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return process.terminationStatus == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Networks

    /// Shows the last scan at once, then a fresh one when it lands.
    private func reload(scanning: Bool) {
        guard let interface = CWWiFiClient.shared().interface() else {
            model.powerOn = false
            return
        }
        model.powerOn = interface.powerOn()
        model.currentIsHotspot = NetworkStatusMonitor.shared.status.hotspot
        apply(interface.cachedScanResults() ?? [], interface: interface)
        guard scanning, model.powerOn, model.locationAllowed else {
            model.scanning = false
            return
        }
        model.scanning = true
        scanGeneration &+= 1
        let token = scanGeneration
        queue.async { [weak self] in
            let results = (try? interface.scanForNetworks(withName: nil, includeHidden: false)) ?? []
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == token else { return }
                self.model.scanning = false
                self.apply(results, interface: interface)
                self.resizeSoon()
            }
        }
    }

    private func apply(_ results: Set<CWNetwork>, interface: CWInterface) {
        let known = Set(interface.configuration()?.networkProfiles.array
            .compactMap { ($0 as? CWNetworkProfile)?.ssid } ?? [])
        let currentSSID = interface.ssid()
        var strongest: [String: CWNetwork] = [:]
        for network in results {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            if let existing = strongest[ssid], existing.rssiValue >= network.rssiValue { continue }
            strongest[ssid] = network
        }
        func entry(_ network: CWNetwork) -> WiFiMenuNetwork {
            let ssid = network.ssid ?? ""
            return WiFiMenuNetwork(ssid: ssid, rssi: network.rssiValue,
                                   secured: !network.supportsSecurity(.none), known: known.contains(ssid))
        }
        if let currentSSID {
            model.current = strongest[currentSSID].map(entry)
                ?? WiFiMenuNetwork(ssid: currentSSID, rssi: interface.rssiValue(), secured: true, known: true)
        } else {
            model.current = nil
        }
        model.others = strongest.values
            .filter { $0.ssid != currentSSID }
            .map(entry)
            // Saved networks first, then by signal, like the system menu.
            .sorted { ($0.known ? 1 : 0, $0.rssi) > ($1.known ? 1 : 0, $1.rssi) }
            .prefix(WiFiMenuLayout.maxOtherNetworks)
            .map { $0 }
    }

    /// After SwiftUI has laid out a change, so the fitted height is current.
    private func resizeSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.resize()
        }
    }

    // MARK: Location

    private func updateLocationAccess() {
        let status = location.authorizationStatus
        // macOS has no "when in use" tier; Always is what an app is granted.
        model.locationAllowed = status == .authorizedAlways
    }

    private func requestLocation() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            dismiss()
            NSWorkspace.shared.open(url)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateLocationAccess()
            if self.isVisible {
                self.reload(scanning: true)
                self.resizeSoon()
            }
        }
    }

    // MARK: Dismissal

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks elsewhere close it. The Duo icon's own click toggles it, so
        // a click on the anchor is left to that.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            self?.clickedOutside()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            self?.clickedOutside()
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }) { monitors.append(m) }
    }

    private func clickedOutside() {
        let point = NSEvent.mouseLocation
        guard let panel, !panel.frame.contains(point),
              !anchor.insetBy(dx: -2, dy: -2).contains(point) else { return }
        dismiss()
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: WiFiMenuView(model: model))
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        let p = WiFiMenuPanel(contentRect: NSRect(x: 0, y: 0, width: WiFiMenuLayout.width, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.contentView = view
        p.isFloatingPanel = true
        // With the control bar's other surfaces: above windows, beneath the bar.
        p.level = NSWindow.Level(rawValue: 22)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel = p
        hosting = view
    }
}

/// Key-capable without activating MSG, so the password field can take typing
/// while the app underneath stays frontmost.
@available(macOS 14.0, *)
private final class WiFiMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
