import AppKit
import QuartzCore
import SwiftUI

// MARK: - Adaptive style

/// Edge HUDs adapt to what's behind them the way the iPhone Home indicator
/// does: white glyphs over dark content, dark glyphs over light content. A
/// dark scrim with white text over a light window read as a grey smudge.
enum EdgeHUDStyle: Equatable {
    case dark(luminance: CGFloat)
    case light

    var isLight: Bool { self == .light }
    var glyph: NSColor { isLight ? NSColor(white: 0.08, alpha: 0.9) : .white }
    var track: NSColor { isLight ? NSColor(white: 0, alpha: 0.18) : NSColor(white: 1, alpha: 0.28) }
    /// The soft glow that separates glyphs from what's behind.
    var glow: NSColor { isLight ? .white : .black }
    var glowOpacity: Float { isLight ? 0.7 : 0.5 }

    /// Hysteresis around the middle so a mid-grey background can't flicker it.
    static func next(for luminance: CGFloat, from current: EdgeHUDStyle) -> EdgeHUDStyle {
        let light = current.isLight ? luminance > 0.5 : luminance > 0.6
        return light ? .light : .dark(luminance: luminance)
    }
}

/// Average brightness of what's on screen under a rect, beneath one window.
enum BackdropLuminance {
    private typealias WindowImageCreator = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
    /// Gone from the headers, still exported (as WindowPreviewCapture uses it).
    private static let create: WindowImageCreator? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageCreator.self)
    }()

    /// 0 (black) … 1 (white), or nil without Screen Recording access.
    static func sample(appKitRect rect: CGRect, below windowID: CGWindowID) -> CGFloat? {
        guard let create, CGPreflightScreenCaptureAccess(), windowID != 0 else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let quartz = CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        guard let image = create(quartz, .optionOnScreenBelowWindow, windowID,
                                 [.nominalResolution, .boundsIgnoreFraming]) else { return nil }
        // Averaged by drawing it into a few pixels.
        let w = 16, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])
        }
        return total / CGFloat(w * h) / 255
    }
}

// MARK: - Edge scrim

/// Dim-and-blur shading rising from the bottom screen edge, feathered to
/// nothing so it never reads as a panel. iPadOS keeps its edge hints readable
/// over live apps because the sheet that raises them dims the whole screen;
/// on the Mac nothing does, so edge HUDs bring their own dimming, only where
/// they sit. Shared by the Touch ID hint and the key HUD so both match.
final class EdgeScrimView: NSVisualEffectView {
    /// Enough to push same-colored text behind well back without a heavy cloud.
    static let tintAlpha: CGFloat = 0.38
    private(set) var style: EdgeHUDStyle = .dark(luminance: 0.5)

    private let feather = CAGradientLayer()
    private let tint = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        // A half-ellipse centred at the bottom edge with a bell-shaped
        // falloff: it reads as shading, never as a shape.
        feather.type = .radial
        feather.startPoint = CGPoint(x: 0.5, y: 0)
        feather.endPoint = CGPoint(x: 1, y: 1)
        let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.3, 0.94), (0.5, 0.74), (0.7, 0.4), (0.85, 0.15), (1, 0)]
        feather.colors = stops.map { NSColor.white.withAlphaComponent($0.1).cgColor }
        feather.locations = stops.map { NSNumber(value: Double($0.0)) }
        layer?.mask = feather
        // The blur alone leaves same-colored text behind legible enough to
        // clash; the tint pushes it back like a dimmed sheet.
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.tintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feather.frame = bounds
        CATransaction.commit()
        tint.frame = bounds
    }

    /// Dark shading under white glyphs — lighter the darker the background
    /// already is — or a light frosting under dark glyphs.
    func apply(_ style: EdgeHUDStyle, animated: Bool) {
        self.style = style
        let tintColor: NSColor
        switch style {
        case .light:
            appearance = NSAppearance(named: .aqua)
            material = .popover
            tintColor = NSColor.white.withAlphaComponent(0.3)
        case .dark(let luminance):
            appearance = NSAppearance(named: .darkAqua)
            material = .hudWindow
            tintColor = NSColor.black.withAlphaComponent(0.16 + (Self.tintAlpha - 0.16) * min(1, luminance / 0.6))
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        tint.layer?.backgroundColor = tintColor.cgColor
        CATransaction.commit()
    }

    func fade(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }
    }
}

// MARK: - Function row geometry

/// Where the built-in keyboard's function row sits under the display, as
/// fractions of the display width — one model for every edge HUD, so a
/// correction lines up the Touch ID hint and the key HUDs together.
///
/// Apple publishes no keycap dimensions. The defaults were measured on a 14″
/// MacBook Pro (M5 Pro) from a photo of the calibration marks
/// (`H1D3S1GN.MSG.calibrateFunctionRow`) over the real keys, projecting the
/// keyboard back onto the screen edge with a 19 mm key pitch: the row starts
/// at 4.76 %, a key is 6.32 % of the display width, esc is 1.45 keys wide;
/// the key face (85.3 % of a key) was then set by eye in Align Keyboard.
/// Every value can still be overridden in defaults.
enum FunctionRow {
    private static func value(_ key: String, _ fallback: Double) -> CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: key) as? Double ?? fallback)
    }
    /// Left edge of esc and right edge of Touch ID.
    static var left: CGFloat { value("functionRowLeft", 0.0476) }
    static var right: CGFloat { value("functionRowRight", 0.9608) }
    /// esc's width in key units (the F keys and Touch ID are one unit each).
    static var escUnits: CGFloat { value("functionRowEscUnits", 1.45) }
    /// A keycap's visible face as a share of its unit; the rest is the gap.
    static var faceRatio: CGFloat { value("functionRowFaceRatio", 0.853) }

    static var unit: CGFloat { (right - left) / (escUnits + 13) }
    static var face: CGFloat { unit * faceRatio }

    /// Center of a key: 0 = esc, 1…12 = F1…F12, 13 = Touch ID.
    static func center(of key: Int) -> CGFloat {
        key == 0 ? left + escUnits * unit / 2 : left + (escUnits + CGFloat(key) - 0.5) * unit
    }

    static var touchID: CGFloat { center(of: 13) }
    /// Spanning F1 and F2.
    static var brightness: CGFloat { (center(of: 1) + center(of: 2)) / 2 }
    /// Spanning F11 and F12 (down and up), as brightness spans F1 and F2.
    static var volume: CGFloat { (center(of: 11) + center(of: 12)) / 2 }
    /// Two keycap faces, without the gaps outside them.
    static var twoKeys: CGFloat { face * 2 }
}

// MARK: - Key HUD

/// Brightness and volume shown at the bottom screen edge right above the keys
/// that changed them (F1/F2, F11/F12) — the way iPadOS shows volume beside its
/// buttons. The keys are on the built-in keyboard, so it lives on the built-in
/// display; with the lid closed `show` declines and the caller falls back.
final class KeyEdgeHUD {
    static let shared = KeyEdgeHUD()

    private init() {
        // A HUD window kept across a display change (the external display
        // unplugged or re-plugged) can end up where it never shows again;
        // drop it and build a fresh one on the next key press.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.discardWindow()
        }
    }

    private func discardWindow() {
        for slot in slots.values {
            slot.hideWork?.cancel()
            slot.sampleTimer?.invalidate()
            slot.window?.orderOut(nil)
        }
        slots.removeAll()
    }

    /// How long the HUD stays after the last key press.
    private static let linger: TimeInterval = 1.4

    private final class Slot {
        let kind: SystemHUDKind
        var window: NSWindow?
        var view: KeyEdgeHUDView?
        var hideWork: DispatchWorkItem?
        var sampleTimer: Timer?
        var isShowing: Bool = false

        init(kind: SystemHUDKind) {
            self.kind = kind
        }
    }

    private var slots: [SystemHUDKind: Slot] = [:]

    private var isEnabled: Bool { EdgeKeys.popupsActive }

    private static func keyX(for kind: SystemHUDKind) -> CGFloat {
        // Over the keys Edge Keys has put the control on, if moved.
        if let center = EdgeKeyStrip.shared.levelCenter(for: kind) { return center }
        return kind == .brightness ? FunctionRow.brightness : FunctionRow.volume
    }

    /// False when it can't be shown (disabled, or no built-in display).
    @discardableResult
    func show(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?) -> Bool {
        guard isEnabled, let screen = NSScreen.screens.first(where: \.isBuiltin) else {
            dismissAll(animated: false)
            return false
        }
        let slot: Slot
        if let existing = slots[kind] {
            slot = existing
        } else {
            slot = Slot(kind: kind)
            slots[kind] = slot
        }

        slot.hideWork?.cancel()
        slot.hideWork = nil

        // The bar spans two keycaps (F1+F2 for brightness), inset by 10 pt.
        let trackWidth = max(20, (screen.frame.width * FunctionRow.twoKeys).rounded() - 10)
        if slot.view?.trackWidth != trackWidth {
            slot.window?.orderOut(nil)
            slot.window = nil
            slot.view = nil
        }
        let size = KeyEdgeHUDView.size(trackWidth: trackWidth)
        let x = screen.frame.minX + screen.frame.width * Self.keyX(for: kind) - size.width / 2
        let frame = CGRect(x: x.rounded(), y: screen.frame.minY, width: size.width, height: size.height)

        let appearing = !slot.isShowing || slot.window == nil
        if slot.window == nil {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let view = KeyEdgeHUDView(trackWidth: trackWidth)
            window.contentView = view
            slot.window = window
            slot.view = view
        }
        if slot.window?.frame != frame { slot.window?.setFrame(frame, display: false) }
        slot.window?.orderFrontRegardless()
        slot.isShowing = true
        if appearing { adaptToBackdrop(slot: slot, animated: false) }
        slot.view?.update(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind,
                          appearing: appearing)
        if slot.sampleTimer == nil {
            // What's behind can change while it's up (scrolling, a window
            // moving); a few-pixel sample is cheap.
            slot.sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self, weak slot] _ in
                guard let self, let slot else { return }
                self.adaptToBackdrop(slot: slot, animated: true)
            }
        }

        let work = DispatchWorkItem { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.dismiss(slot: slot, animated: true)
        }
        slot.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
        return true
    }

    private func adaptToBackdrop(slot: Slot, animated: Bool) {
        guard let window = slot.window, let view = slot.view,
              let luminance = BackdropLuminance.sample(appKitRect: window.frame,
                                                       below: CGWindowID(window.windowNumber)) else { return }
        let style = EdgeHUDStyle.next(for: luminance, from: view.style)
        if style != view.style || !animated { view.apply(style, animated: animated) }
    }

    private func dismiss(slot: Slot, animated: Bool) {
        slot.hideWork?.cancel()
        slot.hideWork = nil
        slot.sampleTimer?.invalidate()
        slot.sampleTimer = nil
        slot.isShowing = false
        guard let window = slot.window, let view = slot.view else { return }
        guard animated else {
            view.resetOpacity()
            window.orderOut(nil)
            return
        }
        view.playHide()
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyEdgeHUDView.hideDuration) { [weak slot] in
            // A key pressed during the fade brought it back.
            guard let slot, !slot.isShowing else { return }
            slot.window?.orderOut(nil)
            slot.view?.resetOpacity()
        }
    }

    func dismiss(animated: Bool) {
        dismissAll(animated: animated)
    }

    func dismissAll(animated: Bool) {
        for slot in slots.values {
            dismiss(slot: slot, animated: animated)
        }
    }
}

private final class KeyEdgeHUDView: NSView {
    static let appearDuration: TimeInterval = 0.20
    static let hideDuration: TimeInterval = 0.28

    /// One line inside the two keys' span — icon, then the track taking the
    /// rest — plus a feathered margin for the scrim on each side.
    static func size(trackWidth: CGFloat) -> CGSize {
        CGSize(width: trackWidth + 90, height: 40)
    }

    /// The two keys' span, inset by 10 pt: icon and track together.
    let trackWidth: CGFloat
    private var trackSize: CGSize { CGSize(width: max(20, trackWidth - Self.iconSide - Self.iconGap), height: 3.5) }
    /// Centre line of the row, up from the screen edge.
    private static let rowY: CGFloat = 12
    private static let iconSide: CGFloat = 18
    private static let iconGap: CGFloat = 8

    private let scrim = EdgeScrimView()
    private let content = NSView()
    private let track = CALayer()
    private let fill = CALayer()
    private let glow = CALayer()
    private let icon = NSImageView()
    private(set) var style: EdgeHUDStyle = .dark(luminance: 0.5)
    private var iconState: (kind: SystemHUDKind, level: CGFloat, muted: Bool, output: AudioOutputKind?)?

    init(trackWidth: CGFloat) {
        self.trackWidth = trackWidth
        super.init(frame: CGRect(origin: .zero, size: Self.size(trackWidth: trackWidth)))
        wantsLayer = true
        scrim.frame = bounds
        addSubview(scrim)
        content.frame = bounds
        content.wantsLayer = true
        addSubview(content)
        guard let root = content.layer else { return }

        let spanX = ((bounds.width - trackWidth) / 2).rounded()
        let trackFrame = CGRect(x: spanX + trackWidth - trackSize.width,
                                y: (Self.rowY - trackSize.height / 2).rounded(),
                                width: trackSize.width, height: trackSize.height)
        track.frame = trackFrame
        track.cornerRadius = trackSize.height / 2
        track.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        track.masksToBounds = true
        root.addSublayer(track)

        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackSize.height)
        fill.backgroundColor = NSColor.white.cgColor
        track.addSublayer(fill)

        // Soft glow on the glyphs, as the lock screen's clock and
        // notifications have; the track can't cast it with masksToBounds.
        glow.frame = trackFrame
        glow.cornerRadius = trackSize.height / 2
        glow.backgroundColor = NSColor.clear.cgColor
        glow.shadowPath = CGPath(roundedRect: glow.bounds, cornerWidth: glow.cornerRadius,
                                 cornerHeight: glow.cornerRadius, transform: nil)
        glow.shadowColor = NSColor.black.cgColor
        glow.shadowOpacity = 0.45
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        root.insertSublayer(glow, below: track)

        icon.frame = CGRect(x: spanX,
                            y: (Self.rowY - Self.iconSide / 2).rounded(),
                            width: Self.iconSide, height: Self.iconSide)
        icon.imageScaling = .scaleProportionallyDown
        icon.wantsLayer = true
        icon.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 7
            s.shadowOffset = .zero
            return s
        }()
        addSubview(icon)

        [track, glow].forEach { $0.opacity = 0 }
        icon.layer?.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                audioOutputKind: AudioOutputKind?, appearing: Bool) {
        let level = max(0, min(1, value))
        iconState = (kind, level, muted, audioOutputKind)
        renderIcon()

        let width = trackSize.width * (muted ? 0 : level)
        CATransaction.begin()
        CATransaction.setAnimationDuration(appearing ? 0 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fill.bounds.size.width = width
        CATransaction.commit()

        guard appearing else { return }
        scrim.fade(to: 1, duration: Self.appearDuration)
        for layer in content.layer?.sublayers ?? [] {
            let fromOpacity = (layer.animation(forKey: "hide") != nil)
                ? (layer.presentation()?.opacity ?? 0)
                : 0
            layer.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.opacity = 1
            layer.add(fade, forKey: "appear")
        }

        let grow = CASpringAnimation(keyPath: "bounds.size.width")
        grow.fromValue = (trackSize.width * 0.40).rounded()
        grow.toValue = trackSize.width
        grow.damping = 28
        grow.stiffness = 300
        grow.duration = grow.settlingDuration
        track.add(grow, forKey: "grow")

        icon.layer?.removeAllAnimations()
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -3
        rise.toValue = 0
        rise.damping = 28
        rise.stiffness = 300
        rise.duration = rise.settlingDuration

        let iconFade = CABasicAnimation(keyPath: "opacity")
        iconFade.fromValue = (icon.layer?.animation(forKey: "hide") != nil)
            ? (icon.layer?.presentation()?.opacity ?? 0)
            : 0
        iconFade.toValue = 1
        iconFade.duration = 0.18
        iconFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        icon.layer?.opacity = 1
        icon.layer?.add(rise, forKey: "rise")
        icon.layer?.add(iconFade, forKey: "appear")
    }

    private func renderIcon() {
        guard let state = iconState else { return }
        icon.image = IndicatorRenderer.systemHUDIcon(
            kind: state.kind, value: state.level, muted: state.muted, audioOutputKind: state.output,
            deviceIcons: true, pointSize: 14, color: style.glyph)
    }

    /// White on dark shading, or dark on light frosting — see `EdgeHUDStyle`.
    func apply(_ style: EdgeHUDStyle, animated: Bool) {
        let recolor = style.isLight != self.style.isLight || !animated
        self.style = style
        scrim.apply(style, animated: animated)
        guard recolor else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        track.backgroundColor = style.track.cgColor
        fill.backgroundColor = style.glyph.cgColor
        glow.shadowColor = style.glow.cgColor
        glow.shadowOpacity = style.glowOpacity * 0.9
        CATransaction.commit()
        let shadow = NSShadow()
        shadow.shadowColor = style.glow.withAlphaComponent(CGFloat(style.glowOpacity))
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = .zero
        icon.shadow = shadow
        renderIcon()
    }

    func playHide() {
        scrim.fade(to: 0, duration: Self.hideDuration)
        for layer in (content.layer?.sublayers ?? []) + [icon.layer].compactMap({ $0 }) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = Self.hideDuration
            layer.opacity = 0
            layer.add(fade, forKey: "hide")
        }
    }

    func resetOpacity() {
        scrim.alphaValue = 0
        for layer in (content.layer?.sublayers ?? []) + [icon.layer].compactMap({ $0 }) {
            layer.removeAllAnimations()
            layer.opacity = 0
        }
        icon.layer?.transform = CATransform3DIdentity
    }
}

// MARK: - Calibration

/// "Align Keyboard": a small panel of sliders that edit `FunctionRow` live
/// while marks over every function-row key show where MSG thinks they are.
/// Opened from the MSG menu, or by posting `H1D3S1GN.MSG.calibrateFunctionRow`.
final class FunctionRowCalibration: NSObject, NSWindowDelegate {
    static let shared = FunctionRowCalibration()
    private var marks: NSWindow?
    private var panel: NSPanel?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("H1D3S1GN.MSG.calibrateFunctionRow"),
            object: nil, queue: .main) { [weak self] _ in self?.open() }
    }

    func open() {
        guard let screen = NSScreen.screens.first(where: \.isBuiltin) else { return }
        showMarks(on: screen)
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = FunctionRowCalibrationModel { [weak self] in self?.refreshMarks() }
        let host = NSHostingView(rootView: FunctionRowCalibrationView(model: model) { [weak self] in
            self?.panel?.close()
        })
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Align Keyboard"
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let size = host.fittingSize
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.minY + 120))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        marks?.orderOut(nil)
        marks = nil
        panel = nil
    }

    private func refreshMarks() {
        guard let screen = NSScreen.screens.first(where: \.isBuiltin) else { return }
        showMarks(on: screen)
    }

    private func showMarks(on screen: NSScreen) {
        let height: CGFloat = 34
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
        let window: NSWindow
        if let marks {
            window = marks
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            marks = window
        }
        window.setFrame(frame, display: false)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let names = ["esc"] + (1...12).map { "F\($0)" } + ["ID"]
        for (i, name) in names.enumerated() {
            let center = FunctionRow.center(of: i) * frame.width
            let gap = FunctionRow.unit - FunctionRow.face
            let width = (i == 0 ? FunctionRow.escUnits * FunctionRow.unit - gap : FunctionRow.face) * frame.width
            let mark = CALayer()
            mark.frame = CGRect(x: center - width / 2, y: 2, width: width, height: 5)
            mark.cornerRadius = 2.5
            mark.backgroundColor = (i == 0 || i == 13 ? NSColor.systemOrange : NSColor.systemGreen).cgColor
            view.layer?.addSublayer(mark)
            let label = CATextLayer()
            label.string = name
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.fontSize = 11
            label.alignmentMode = .center
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            label.cornerRadius = 3
            label.contentsScale = screen.backingScaleFactor
            label.frame = CGRect(x: center - 16, y: 10, width: 32, height: 15)
            view.layer?.addSublayer(label)
        }
        window.contentView = view
        window.orderFrontRegardless()
    }
}

/// The row as the sliders see it: where it's centred and how wide it is,
/// stored back as the left and right edges `FunctionRow` reads.
final class FunctionRowCalibrationModel: ObservableObject {
    static let defaults: (center: Double, width: Double, esc: Double, face: Double) = (0.5042, 0.9132, 1.45, 0.853)
    private let onChange: () -> Void

    @Published var center: Double { didSet { save() } }
    @Published var width: Double { didSet { save() } }
    @Published var esc: Double { didSet { save() } }
    @Published var face: Double { didSet { save() } }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        center = Double((FunctionRow.left + FunctionRow.right) / 2)
        width = Double(FunctionRow.right - FunctionRow.left)
        esc = Double(FunctionRow.escUnits)
        face = Double(FunctionRow.faceRatio)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(center - width / 2, forKey: "functionRowLeft")
        d.set(center + width / 2, forKey: "functionRowRight")
        d.set(esc, forKey: "functionRowEscUnits")
        d.set(face, forKey: "functionRowFaceRatio")
        onChange()
    }

    func reset() {
        let d = UserDefaults.standard
        ["functionRowLeft", "functionRowRight", "functionRowEscUnits", "functionRowFaceRatio"]
            .forEach { d.removeObject(forKey: $0) }
        // Setting the sliders writes their values back; clear again so the
        // built-in defaults stay in charge.
        (center, width, esc, face) = Self.defaults
        ["functionRowLeft", "functionRowRight", "functionRowEscUnits", "functionRowFaceRatio"]
            .forEach { d.removeObject(forKey: $0) }
        onChange()
    }
}

struct FunctionRowCalibrationView: View {
    @ObservedObject var model: FunctionRowCalibrationModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Line the marks at the bottom of the screen up with the keys below it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            row("Position", value: $model.center, range: 0.45...0.55, step: 0.0005,
                shown: String(format: "%+.1f pt", (model.center - 0.5) * screenWidth))
            row("Row width", value: $model.width, range: 0.80...1.0, step: 0.001,
                shown: String(format: "%.0f pt", model.width * screenWidth))
            row("esc width", value: $model.esc, range: 1.0...2.2, step: 0.01,
                shown: String(format: "%.2f keys", model.esc))
            row("Key face", value: $model.face, range: 0.7...1.0, step: 0.005,
                shown: String(format: "%.0f%%", model.face * 100))
            HStack {
                Button("Reset") { model.reset() }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private var screenWidth: Double {
        Double(NSScreen.screens.first(where: \.isBuiltin)?.frame.width ?? 1512)
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                     step: Double, shown: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(shown).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                Slider(value: value, in: range)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
