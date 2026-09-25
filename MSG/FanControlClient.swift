import Foundation
import ServiceManagement

/// App-side owner of the privileged fan daemon.
///
/// Replaces the previous model — an `osascript ... with administrator
/// privileges` prompt launching a C helper behind a unix socket guarded by a
/// shared token — with the one macOS actually provides for this:
///
///   * `SMAppService.daemon` registers a LaunchDaemon that ships inside the app
///     bundle. The user approves it once in System Settings ▸ Login Items
///     instead of typing their password every session, and launchd owns the
///     process lifetime.
///   * `NSXPCConnection` to a mach service replaces the socket. The helper sets
///     a code-signing requirement on its listener, so the kernel refuses any
///     peer that is not the signed MSG binary — the old token only proved the
///     caller ran as the same user, which any process of theirs could manage.
///   * A heartbeat holds a lease on manual control. Stop sending it and the
///     helper puts the fans back on automatic by itself, so a crash can no
///     longer leave them pinned (SMC manual mode survives process death).
@available(macOS 14.0, *)
final class FanControlClient {

    enum Access: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case unavailable
    }

    static let shared = FanControlClient()

    private(set) var snapshot = FanHelperSnapshot()
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private let lock = NSLock()

    private init() {}

    private static var service: SMAppService {
        SMAppService.daemon(plistName: FanHelperID.plistName)
    }

    var access: Access {
        switch Self.service.status {
        case .notRegistered:     return .notRegistered
        case .enabled:           return .enabled
        case .requiresApproval:  return .requiresApproval
        case .notFound:          return .unavailable
        @unknown default:        return .unavailable
        }
    }

    /// Registers the daemon if it isn't already. Returns the state afterwards;
    /// `.requiresApproval` means the user must switch it on in System Settings,
    /// which `openSettings()` takes them to.
    @discardableResult
    func registerIfNeeded() -> Access {
        let current = access
        guard current == .notRegistered else { return current }
        do {
            try Self.service.register()
            NSLog("[fan] daemon registered")
        } catch {
            NSLog("[fan] daemon registration failed: %@", String(describing: error))
        }
        return access
    }

    func unregister() {
        stopHeartbeat()
        invalidate()
        try? Self.service.unregister()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Connection

    private func proxy() -> FanHelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: FanHelperID.helperID,
                                    options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = { [weak self] in self?.clearConnection() }
            c.interruptionHandler = { [weak self] in self?.clearConnection() }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[fan] XPC error: %@", String(describing: error))
        } as? FanHelperProtocol
    }

    private func clearConnection() {
        lock.lock(); connection = nil; lock.unlock()
    }

    private func invalidate() {
        lock.lock(); connection?.invalidate(); connection = nil; lock.unlock()
    }

    // MARK: Commands
    //
    // Every reply is decoded on the caller's queue; XPC delivers on its own.

    /// Completions fire on XPC's own delivery queue, never hopped to main.
    ///
    /// `HardwareMonitor.sendViaDaemon` calls in from the main thread and blocks
    /// on a semaphore to keep the existing synchronous call sites; a completion
    /// bounced back to main could then never run. UI callers hop themselves.
    private func send(_ body: (FanHelperProtocol, @escaping (Data) -> Void) -> Void,
                      completion: ((FanHelperReply?) -> Void)?) {
        guard let p = proxy() else { completion?(nil); return }
        body(p) { [weak self] data in
            let reply = FanHelperCodec.decode(data)
            if let s = reply?.snapshot { self?.snapshot = s }
            completion?(reply)
        }
    }

    func setPercent(_ pct: Double, completion: ((FanHelperReply?) -> Void)? = nil) {
        send({ $0.setPercent(pct, withReply: $1) }) { [weak self] reply in
            if reply?.ok == true { self?.startHeartbeat() }
            completion?(reply)
        }
    }

    func restoreAutomatic(completion: ((FanHelperReply?) -> Void)? = nil) {
        stopHeartbeat()
        send({ $0.restoreAutomatic(withReply: $1) }, completion: completion)
    }

    func setPowerMode(_ mode: Int, completion: ((FanHelperReply?) -> Void)? = nil) {
        send({ $0.setPowerMode(mode, withReply: $1) }, completion: completion)
    }

    func refreshStatus(completion: ((FanHelperReply?) -> Void)? = nil) {
        send({ $0.status(withReply: $1) }, completion: completion)
    }

    // MARK: Heartbeat

    /// Well inside the helper's lease so an ordinary hiccup — a busy main
    /// thread, a slow SMC sweep — never reads as "the app is gone".
    private static let heartbeatInterval: TimeInterval = 5

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.send({ $0.heartbeat(withReply: $1) }, completion: nil)
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
