import AppKit

/// Own only the auto-hide change made by this feature. The journal survives a
/// crash; the next launch can restore the original value (including absence).
final class TilingMenuBar {
    private let defaults: UserDefaults
    private let read: () -> Bool?
    private let write: (Bool?) -> Bool
    private let journalKey = "tilingMenuBarRestore"
    private var active = false
    private var appliedValue: Bool?

    init(defaults: UserDefaults = .standard,
         read: @escaping () -> Bool? = TilingMenuBar.readSystemValue,
         write: @escaping (Bool?) -> Bool = TilingMenuBar.writeSystemValue) {
        self.defaults = defaults
        self.read = read
        self.write = write
    }

    func setEnabled(_ enabled: Bool) {
        setAutoHideOverride(enabled ? true : nil)
    }

    /// `true` hides the native menu bar, `false` keeps it visible, and `nil`
    /// restores the value that belonged to the user before tiling took over.
    func setAutoHideOverride(_ desired: Bool?) {
        if let desired {
            if active, appliedValue == desired { return }
            active = true
            // Resume ownership after an unclean exit without replacing the backup.
            if defaults.dictionary(forKey: journalKey) == nil {
                let previous = read()
                defaults.set(["hadValue": previous != nil,
                              "value": previous ?? false,
                              "applied": desired], forKey: journalKey)
                guard defaults.synchronize() else {
                    active = false
                    NSLog("MSG: could not save the menu bar restore value")
                    return
                }
            } else if var saved = defaults.dictionary(forKey: journalKey) {
                saved["applied"] = desired
                defaults.set(saved, forKey: journalKey)
                defaults.synchronize()
            }
            appliedValue = desired
            guard read() != desired else { return }
            if !write(desired) {
                NSLog("MSG: could not apply the tiling menu bar mode; restore value retained")
            }
        } else {
            active = false
            appliedValue = nil
            guard let saved = defaults.dictionary(forKey: journalKey) else { return }
            let applied = saved["applied"] as? Bool ?? true
            // A later manual change belongs to the user. Do not overwrite it.
            let current = read()
            if current == applied {
                let original: Bool? = (saved["hadValue"] as? Bool == true) ? saved["value"] as? Bool : nil
                if current != original, !write(original) {
                    NSLog("MSG: could not restore menu bar auto-hide; will retry at next launch")
                    return
                }
            }
            defaults.removeObject(forKey: journalKey)
            defaults.synchronize()
        }
    }

    private static func readSystemValue() -> Bool? {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (CFPreferencesCopyValue("_HIHideMenuBar" as CFString,
                                       kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost) as? NSNumber)?.boolValue
    }

    private static func writeSystemValue(_ value: Bool?) -> Bool {
        CFPreferencesSetValue("_HIHideMenuBar" as CFString, value.map { NSNumber(value: $0) },
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                       kCFPreferencesAnyHost) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
            object: nil, userInfo: nil, deliverImmediately: true)
        return readSystemValue() == value
    }
}
