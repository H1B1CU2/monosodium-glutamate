import Foundation

@main
struct TilingMenuBarTests {
    static func main() {
        let name = "MSG.TilingMenuBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var value: Bool? = false
        var writes = 0
        var failWrite = false
        func owner() -> TilingMenuBar {
            TilingMenuBar(defaults: defaults, read: { value }, write: { new in
                writes += 1
                if failWrite { return false }
                value = new
                return true
            })
        }
        let first = owner()
        first.setEnabled(true)
        assert(value == true && writes == 1)
        first.setEnabled(true)
        assert(writes == 1, "repeated settings updates must not overwrite the restore value")
        first.setEnabled(false)
        assert(value == false && writes == 2)
        first.setEnabled(false)
        assert(writes == 2)

        first.setAutoHideOverride(false)
        assert(value == false, "hybrid mode should keep the native menu bar visible")
        first.setAutoHideOverride(true)
        assert(value == true, "switching modes should hide the native menu bar without replacing the backup")
        first.setAutoHideOverride(false)
        assert(value == false, "switching back to hybrid should reveal the native menu bar")
        first.setAutoHideOverride(nil)
        assert(value == false, "leaving tiling should restore the original menu bar preference")

        value = nil
        first.setEnabled(true)
        assert(value == true)
        first.setEnabled(false)
        assert(value == nil, "an absent preference must be removed, not replaced by false")

        value = true
        let before = writes
        first.setEnabled(true)
        first.setEnabled(false)
        assert(value == true && writes == before, "existing auto-hide belongs to the user")

        value = false
        first.setEnabled(true)
        value = false // User overrides MSG in System Settings.
        let changed = writes
        first.setEnabled(true)
        first.setEnabled(false)
        assert(value == false && writes == changed, "do not overwrite a later manual change")

        first.setEnabled(true)
        let afterCrash = owner()
        afterCrash.setEnabled(true)
        afterCrash.setEnabled(false)
        assert(value == false, "relaunch while enabled must retain the original backup")

        first.setEnabled(false)
        first.setEnabled(true)
        owner().setEnabled(false)
        assert(value == false, "launch while disabled must recover from an unclean exit")

        first.setEnabled(false)
        first.setEnabled(true)
        failWrite = true
        first.setEnabled(false)
        assert(value == true && defaults.dictionary(forKey: "tilingMenuBarRestore") != nil)
        failWrite = false
        owner().setEnabled(false)
        assert(value == false && defaults.dictionary(forKey: "tilingMenuBarRestore") == nil,
               "failed restoration must retain the journal for retry")
        print("TilingMenuBarTests passed: restore, absence, preexisting auto-hide, manual override, crash recovery and retry")
    }
}
