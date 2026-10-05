import AppKit
import SwiftUI

@main
struct SettingsControlsTests {
    @MainActor static func main() {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { nativeControlChecks() }
        else { print("Native Liquid Glass checks require macOS 27; fallback compiled.") }
        #else
        print("Native Liquid Glass checks require the macOS 27 SDK; fallback compiled.")
        #endif
    }

    #if compiler(>=6.4)
    @available(macOS 27.0, *)
    @MainActor private static func nativeControlChecks() {
        _ = NSApplication.shared
        var selection = "first"
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let options = [SettingsSegment("First", "first"), SettingsSegment("Second", "second"),
                       SettingsSegment("Reserved", "reserved", enabled: false)]
        func picker(navigation: Bool = true, enabled: Bool = true) -> AnyView {
            AnyView(SettingsSegmentedPicker(title: "Category", selection: binding, options: options,
                                            navigation: navigation, showsLabel: false).disabled(!enabled))
        }
        let hosting = NSHostingView(rootView: picker())
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 60)
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        func control(in view: NSView) -> NSSegmentedControl? {
            if let view = view as? NSSegmentedControl { return view }
            return view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        settle()
        guard let tabs = control(in: hosting) else { preconditionFailure("Native segmented control was not hosted") }
        precondition(tabs.role == .tabs && tabs.borderShape == .capsule)
        precondition(tabs.segmentCount == 3 && tabs.selectedSegment == 0)
        precondition(!tabs.isEnabled(forSegment: 2), "Reserved values stay disabled")
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action!, to: tabs.target)
        precondition(selection == "second", "A native action must update the SwiftUI binding")
        tabs.selectedSegment = 2
        tabs.sendAction(tabs.action!, to: tabs.target)
        precondition(selection == "second", "Disabled segments must not change a persisted value")

        hosting.rootView = picker(navigation: false)
        settle()
        let values = control(in: hosting)!
        precondition(values.role == .valueSelection && values.selectedSegment == 1,
                     "Updating the selector must reflect the model and its semantic role")
        hosting.rootView = picker(navigation: false, enabled: false)
        settle()
        let disabled = control(in: hosting)!
        precondition((0..<disabled.segmentCount).allSatisfy { !disabled.isEnabled(forSegment: $0) },
                     "Parent disabling must reach the native control")

        hosting.rootView = picker()
        hosting.setFrameSize(CGSize(width: 260, height: 60))
        settle()
        let narrowed = control(in: hosting)!
        precondition(narrowed.frame.minX >= 0 && narrowed.frame.maxX <= narrowed.superview!.bounds.maxX,
                     "The control must fit the width proposed by the pane")
        print("Settings controls: native binding, disabled options, parent disabling, roles and sizing passed")
    }
    #endif
}
