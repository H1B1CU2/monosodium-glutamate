import AppKit

// MARK: - Enums

enum DisplayStyle: String, CaseIterable {
    case pill        = "Pill"
    case numbers     = "Numbers"
    case boldNumber  = "Number (current only)"
    case dots        = "Dots"
}

enum AnimationStyle: String, CaseIterable {
    case none   = "None"
    case solid  = "Solid"
    case liquid = "Liquid"
    case jelly  = "Jelly"
}

enum StackMode: String, CaseIterable {
    case inline  = "Inline"
    case stack   = "Stack"
    case dynamic = "Dynamic"
}

enum DisplayOrderMode: String, CaseIterable {
    case physicalDetection = "Physical Display Detection"
    case prioritizeMain    = "Prioritize Main Display"
}

enum FocusDetectionMode: String, CaseIterable {
    case off     = "Off"
    case click   = "Click Detection"
    case dynamic = "Dynamic Detection"
}

// MARK: - Settings

/// Centralized persistent settings. All values flush to UserDefaults on change.
/// Subscribe to `onChange` to react. The `category` argument tells subscribers
/// which subsystem(s) need to refresh.
final class Settings {

    enum Category {
        case corners        // overlay redraw
        case indicator      // status bar render
        case structural     // rebuild windows/menus
    }

    private enum Key {
        static let cornerRadius             = "cornerRadius"
        static let topCornersEnabled        = "topCornersEnabled"
        static let bottomCornersEnabled     = "bottomCornersEnabled"
        static let topCornersUnderMenuBar   = "topCornersUnderMenuBar"
        static let extCornerRadius          = "extCornerRadius"
        static let extTopCornersEnabled     = "extTopCornersEnabled"
        static let extBottomCornersEnabled  = "extBottomCornersEnabled"
        static let extTopCornersUnderMenuBar = "extTopCornersUnderMenuBar"
        static let mirrorMainDisplay        = "mirrorMainDisplay"
        static let externalMonitorCorners   = "externalMonitorCorners"
        static let displayStyle             = "displayStyle"
        static let animationStyle           = "animationStyle"
        static let stackMode                = "stackMode"
        static let displayOrderMode         = "displayOrderMode"
        static let hideInMissionControl      = "hideInMissionControl"
        static let focusDetectionMode       = "focusDetectionMode"
        static let displayOrder             = "displayOrder"
    }

    static let shared = Settings()

    var onChange: ((Category) -> Void)?

    // MARK: Corners
    var cornerRadius: CGFloat {
        didSet { save(); if mirrorMainDisplay { extCornerRadius = cornerRadius }; onChange?(.corners) }
    }
    var topCornersEnabled: Bool {
        didSet { save(); if mirrorMainDisplay { extTopCornersEnabled = topCornersEnabled }; onChange?(.corners) }
    }
    var bottomCornersEnabled: Bool {
        didSet { save(); if mirrorMainDisplay { extBottomCornersEnabled = bottomCornersEnabled }; onChange?(.corners) }
    }
    var topCornersUnderMenuBar: Bool {
        didSet { save(); if mirrorMainDisplay { extTopCornersUnderMenuBar = topCornersUnderMenuBar }; onChange?(.corners) }
    }

    // MARK: External corners
    var extCornerRadius: CGFloat       { didSet { save(); onChange?(.corners) } }
    var extTopCornersEnabled: Bool     { didSet { save(); onChange?(.corners) } }
    var extBottomCornersEnabled: Bool  { didSet { save(); onChange?(.corners) } }
    var extTopCornersUnderMenuBar: Bool { didSet { save(); onChange?(.corners) } }

    var mirrorMainDisplay: Bool {
        didSet {
            save()
            if mirrorMainDisplay {
                extCornerRadius = cornerRadius
                extTopCornersEnabled = topCornersEnabled
                extBottomCornersEnabled = bottomCornersEnabled
                extTopCornersUnderMenuBar = topCornersUnderMenuBar
            }
            onChange?(.structural)
        }
    }
    var externalMonitorCorners: Bool { didSet { save(); onChange?(.structural) } }
    var hideInMissionControl: Bool    { didSet { save(); onChange?(.corners) } }

    // MARK: Indicator
    var displayStyle: DisplayStyle {
        didSet {
            save()
            if displayStyle != .pill && displayStyle != .dots { stackMode = .stack }
            if (displayStyle == .numbers || displayStyle == .boldNumber || displayStyle == .dots) && animationStyle == .jelly {
                animationStyle = .liquid
            }
            onChange?(.indicator)
        }
    }
    var animationStyle: AnimationStyle  { didSet { save() } }
    var stackMode: StackMode            { didSet { save(); onChange?(.indicator) } }
    var displayOrderMode: DisplayOrderMode { didSet { save(); onChange?(.indicator) } }
    var focusDetectionMode: FocusDetectionMode { didSet { save(); onChange?(.indicator) } }
    var displayOrder: [Int]             { didSet { save(); onChange?(.indicator) } }

    // MARK: Init

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.cornerRadius:           CGFloat(10),
            Key.topCornersEnabled:      true,
            Key.bottomCornersEnabled:   true,
            Key.topCornersUnderMenuBar: false,
            Key.extCornerRadius:        CGFloat(10),
            Key.extTopCornersEnabled:    true,
            Key.extBottomCornersEnabled: true,
            Key.extTopCornersUnderMenuBar: false,
            Key.mirrorMainDisplay:      false,
            Key.externalMonitorCorners: false,
            Key.hideInMissionControl:   true,
            Key.displayStyle:           DisplayStyle.pill.rawValue,
            Key.animationStyle:         AnimationStyle.liquid.rawValue,
            Key.stackMode:              StackMode.stack.rawValue,
            Key.displayOrderMode:       DisplayOrderMode.prioritizeMain.rawValue,
            Key.focusDetectionMode:     FocusDetectionMode.click.rawValue,
            Key.displayOrder:           [Int](),
        ])

        cornerRadius             = CGFloat(d.float(forKey: Key.cornerRadius))
        topCornersEnabled        = d.bool(forKey: Key.topCornersEnabled)
        bottomCornersEnabled     = d.bool(forKey: Key.bottomCornersEnabled)
        topCornersUnderMenuBar   = d.bool(forKey: Key.topCornersUnderMenuBar)
        extCornerRadius          = CGFloat(d.float(forKey: Key.extCornerRadius))
        extTopCornersEnabled     = d.bool(forKey: Key.extTopCornersEnabled)
        extBottomCornersEnabled  = d.bool(forKey: Key.extBottomCornersEnabled)
        extTopCornersUnderMenuBar = d.bool(forKey: Key.extTopCornersUnderMenuBar)
        mirrorMainDisplay        = d.bool(forKey: Key.mirrorMainDisplay)
        externalMonitorCorners   = d.bool(forKey: Key.externalMonitorCorners)
        hideInMissionControl     = d.bool(forKey: Key.hideInMissionControl)

        displayStyle      = DisplayStyle(rawValue: d.string(forKey: Key.displayStyle) ?? "") ?? .pill
        animationStyle    = AnimationStyle(rawValue: d.string(forKey: Key.animationStyle) ?? "") ?? .liquid
        stackMode         = StackMode(rawValue: d.string(forKey: Key.stackMode) ?? "") ?? .stack
        displayOrderMode  = DisplayOrderMode(rawValue: d.string(forKey: Key.displayOrderMode) ?? "") ?? .prioritizeMain
        focusDetectionMode = FocusDetectionMode(rawValue: d.string(forKey: Key.focusDetectionMode) ?? "") ?? .click
        displayOrder      = (d.array(forKey: Key.displayOrder) as? [Int]) ?? []
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Float(cornerRadius),          forKey: Key.cornerRadius)
        d.set(topCornersEnabled,            forKey: Key.topCornersEnabled)
        d.set(bottomCornersEnabled,         forKey: Key.bottomCornersEnabled)
        d.set(topCornersUnderMenuBar,       forKey: Key.topCornersUnderMenuBar)
        d.set(Float(extCornerRadius),       forKey: Key.extCornerRadius)
        d.set(extTopCornersEnabled,         forKey: Key.extTopCornersEnabled)
        d.set(extBottomCornersEnabled,      forKey: Key.extBottomCornersEnabled)
        d.set(extTopCornersUnderMenuBar,    forKey: Key.extTopCornersUnderMenuBar)
        d.set(mirrorMainDisplay,            forKey: Key.mirrorMainDisplay)
        d.set(externalMonitorCorners,       forKey: Key.externalMonitorCorners)
        d.set(hideInMissionControl,         forKey: Key.hideInMissionControl)
        d.set(displayStyle.rawValue,        forKey: Key.displayStyle)
        d.set(animationStyle.rawValue,      forKey: Key.animationStyle)
        d.set(stackMode.rawValue,           forKey: Key.stackMode)
        d.set(displayOrderMode.rawValue,    forKey: Key.displayOrderMode)
        d.set(focusDetectionMode.rawValue,  forKey: Key.focusDetectionMode)
        d.set(displayOrder,                 forKey: Key.displayOrder)
    }
}
