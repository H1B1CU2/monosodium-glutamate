import Foundation

/// Names and code requirements shared by the app and the privileged helper.
///
/// Both sides compile this file, so a rename can't drift between them.
enum FanHelperID {
    static let teamID = "47TAK6TXPB"
    static let appBundleID = "H1D3S1GN.MSG"

    /// Mach service the daemon advertises, and the launchd job label.
    static let helperID = "\(appBundleID).fan-helper"
    static let plistName = "\(helperID).plist"

    /// Only a binary matching this may drive the fans. Enforced by the kernel
    /// through `NSXPCListener.setConnectionCodeSigningRequirement`, so a
    /// process merely running as the same user — which is all the old shared
    /// token proved — no longer qualifies.
    static let appRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(appBundleID)\""
}

/// Fan state the helper reports back.
struct FanHelperSnapshot: Codable {
    var mode: String = "auto"        // "auto" | "manual"
    var percent: Double? = nil       // last commanded percent while manual
    var fanCount: Int = 0
    /// Seconds until the watchdog restores automatic control, nil when on auto.
    var secondsUntilRestore: Double? = nil
}

struct FanHelperReply: Codable {
    var ok: Bool
    var snapshot: FanHelperSnapshot
    var error: String? = nil
}

@objc protocol FanHelperProtocol {
    /// Percent 0...100. The helper holds it only while heartbeats keep arriving.
    func setPercent(_ percent: Double, withReply reply: @escaping (Data) -> Void)
    func restoreAutomatic(withReply reply: @escaping (Data) -> Void)
    func setPowerMode(_ mode: Int, withReply reply: @escaping (Data) -> Void)
    /// Renews the lease; without it the watchdog returns the fans to automatic.
    func heartbeat(withReply reply: @escaping (Data) -> Void)
    func status(withReply reply: @escaping (Data) -> Void)
}

enum FanHelperCodec {
    static func encode(_ reply: FanHelperReply) -> Data {
        (try? JSONEncoder().encode(reply))
            ?? Data(#"{"ok":false,"snapshot":{"mode":"auto","fanCount":0}}"#.utf8)
    }
    static func decode(_ data: Data) -> FanHelperReply? {
        try? JSONDecoder().decode(FanHelperReply.self, from: data)
    }
}
