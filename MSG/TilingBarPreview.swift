import AppKit
import SwiftUI

// MARK: - Layout

/// Geometry of the control bar's hover previews — the window card and the
/// Desktop strip. Both are built from `DockWindowCard`, the card the Dock
/// preview and the Cmd-Tab switcher use, inside the same material panel as
/// the Notch preview and the switcher, so every preview surface in MSG reads
/// as one family.
///
/// Radii are derived outward from the card, never set per surface, so a
/// padding change can't pinch a corner.
@available(macOS 14.0, *)
enum TilingBarPreviewLayout {
    /// `DockWindowCard`'s frame radius, asserted there and mirrored here.
    static let windowCardRadius: CGFloat = 14
    /// `DockWindowCard`'s frame padding around its thumbnail, either side.
    static let windowCardFrame: CGFloat = 6
    /// Widest a card may get, as a multiple of its height — the switcher's cap.
    static let maxCardAspect: CGFloat = 2.6
    /// Gap between a card's thumbnail frame and its caption.
    static let captionGap: CGFloat = 10

    /// The window card panel's padding around its content.
    static let padding: CGFloat = 12
    /// Concentric with the card it holds: 26, the Notch and switcher panels' radius.
    static var cardRadius: CGFloat { windowCardRadius + padding }

    /// App icon and name above a card, as in the Notch preview and switcher.
    static let identityHeight: CGFloat = 20
    static let identityGap: CGFloat = 8

    static let gapBelowBar: CGFloat = 6
    static let tuck: CGFloat = 12
    static let screenInset: CGFloat = 8

    static func thumbnailWidth(aspect: CGFloat, height: CGFloat) -> CGFloat {
        min(height * maxCardAspect, max(80, height * aspect))
    }

    static func aspect(of image: NSImage) -> CGFloat {
        image.size.height > 0 ? image.size.width / image.size.height : 1.4
    }

    /// Height `DockWindowCard` gives a window's caption at this card width:
    /// the Dock preview's measure — one line or two of 10pt — or 0 for none.
    static func captionHeight(for window: CapturedWindow, appName: String, cardWidth: CGFloat) -> CGFloat {
        guard let caption = dockPreviewCaption(for: window, appName: appName) else { return 0 }
        let attr = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 10)])
        let rect = attr.boundingRect(
            with: CGSize(width: max(0, cardWidth - 4), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return rect.height > 15 ? 28 : 14
    }
}

/// The Notch preview and switcher panel: thin material with a hairline edge.
@available(macOS 14.0, *)
struct PreviewPanelChrome: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// App icon and name above a card, brightening while the card is active —
/// the Notch preview's and switcher's identity row.
@available(macOS 14.0, *)
struct PreviewIdentityRow: View {
    let icon: NSImage?
    let name: String
    let active: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .scaleEffect(active ? 1.08 : 1.0)
                    .shadow(color: .black.opacity(active ? 0.35 : 0.0), radius: active ? 3 : 0, y: active ? 1 : 0)
            }
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? .primary : .secondary)
                .opacity(active ? 1.0 : 0.72)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .frame(width: width, height: TilingBarPreviewLayout.identityHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: active)
    }
}

// MARK: - Model

@available(macOS 14.0, *)
private final class TilingBarPreviewModel: ObservableObject {
    @Published var window: CapturedWindow?
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var pid: pid_t = 0
    @Published var thumbHeight: CGFloat = 140
    /// Fixed up front, so the panel's size is known without measuring SwiftUI.
    @Published var captionHeight: CGFloat = 0
    @Published var contentOpacity: CGFloat = 1.0
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onFullscreen: () -> Void = {}
    var onDismiss: () -> Void = {}
    var panelFrame: () -> CGRect = { .zero }
}

// MARK: - View

@available(macOS 14.0, *)
private struct TilingBarPreviewView: View {
    @ObservedObject var model: TilingBarPreviewModel
    @State private var isHovering = false

    var body: some View {
        let layout = TilingBarPreviewLayout.self

        VStack(alignment: .leading, spacing: layout.identityGap) {
            if let window = model.window {
                let cardWidth = layout.thumbnailWidth(aspect: layout.aspect(of: window.image),
                                                      height: model.thumbHeight) + layout.windowCardFrame * 2
                PreviewIdentityRow(icon: model.appIcon, name: model.appName,
                                   active: isHovering, width: cardWidth)
                DockWindowCard(window: window,
                               appName: model.appName,
                               height: model.thumbHeight,
                               maxWidth: model.thumbHeight * layout.maxCardAspect,
                               action: model.onSelect,
                               onClose: model.onClose,
                               captionHeight: model.captionHeight > 0 ? model.captionHeight : nil,
                               onHoverChanged: { isHovering = $0 },
                               pid: model.pid,
                               appIcon: model.appIcon,
                               sourcePanelFrame: model.panelFrame,
                               onDismissPanel: model.onDismiss,
                               isHidden: PreviewHiddenStyle.isHidden(pid: model.pid, windowID: window.id))
                    .id(window.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .opacity(model.contentOpacity)
        .padding(layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: layout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: layout.cardRadius, style: .continuous))
    }
}

// MARK: - Controller

/// Hover previews for the tiling control bar's window icons.
///
/// Rest on an icon and the window it stands for drops down beneath it. Drag
/// that card onto the desktop and the window moves to the Space being looked
/// at. The drag is `WindowPreviewDragController`, shared with the Dock and
/// Notch previews, so all three surfaces pick up, carry and land identically.
@available(macOS 14.0, *)
final class TilingBarPreviewController {

    /// One hover, as the bar reports it.
    struct Target {
        let window: TilingBarWindow
        /// The icon's rect on screen.
        let icon: CGRect
        /// The bar's frame on screen; the card hangs from its bottom edge.
        let bar: CGRect
        /// Space the bar is currently showing, to tell whether the window is
        /// on it or somewhere else.
        let currentSpace: Int
        let activate: () -> Void
        var onCancel: () -> Void = {}
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<TilingBarPreviewView>?
    private let model = TilingBarPreviewModel()

    private var shown: Target?
    private var pending: Target?
    private var pendingCapture: CapturedWindow?
    private var hoverDelayElapsed = false

    private var hoverTimer: Timer?
    private var dismissTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var timeline: PreviewPanelTimeline?
    private var monitors: [Any] = []
    private var generation = 0

    /// Hover intent. Fast and responsive (0.18s), but ignores quick sweeps across the bar.
    private static let hoverDelay: TimeInterval = 0.18
    /// How long the pointer may be outside the card before it closes, so a
    /// diagonal path from icon to card doesn't clip a corner and lose it.
    private static let dismissGrace: TimeInterval = 0.20

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var isVisible: Bool { shown != nil && panel?.isVisible == true }
    var currentPanelFrame: NSRect? {
        guard let panel, panel.isVisible, shown != nil else { return nil }
        var f = panel.frame
        if let target = shown {
            let maxTop = target.bar.minY - TilingBarPreviewLayout.gapBelowBar
            if f.maxY > maxTop {
                f.origin.y = maxTop - f.height
            }
        }
        return f
    }

    // MARK: Hover input

    /// The bar's report of which icon the pointer is on, or nil for none.
    func hover(_ target: Target?, morphFrom: NSRect? = nil) {
        guard !WindowPreviewDragController.shared.isDragging else { return }
        guard let target, AppSettings.shared.tilingControlBarPreviews else {
            cancelPending()
            if shown != nil { scheduleDismissCheck() } else { removeMonitors() }
            return
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        installMonitors()

        if let shown {
            guard shown.window.windowID != target.window.windowID else {
                // Same window; keep the latest geometry and callbacks.
                self.shown = target
                return
            }
            // A card is already open: follow the pointer straight to the next
            // icon with no second hover delay, the way the Dock preview does.
            switchTo(target)
            return
        }

        if let morphFrom {
            // Morphing directly from another preview on the bar (e.g. Deskspace preview).
            // No hover delay: intent is already established.
            cancelPending()
            generation &+= 1
            let token = generation
            let fallbackTitle = target.window.title.isEmpty ? nil : target.window.title
            let window = cachedWindow(for: target)
                ?? CapturedWindow(id: target.window.windowID,
                                  image: target.window.icon ?? NSImage(),
                                  title: fallbackTitle, bounds: target.window.frame)
            present(target, window: window, morphFrom: morphFrom)
            captureTask = Task { @MainActor [weak self] in
                let captured = await WindowPreviewCapture.captureWindow(pid: target.window.pid,
                                                                        windowID: target.window.windowID)
                guard let self, !Task.isCancelled else { return }
                self.captureLanded(captured, for: target, token: token)
            }
            return
        }

        guard pending?.window.windowID != target.window.windowID else { return }
        cancelPending()
        generation &+= 1
        let token = generation
        pending = target

        // Capture during the delay rather than after it, so the card can open
        // with its real image the moment intent is established.
        captureTask = Task { @MainActor [weak self] in
            let captured = await WindowPreviewCapture.captureWindow(pid: target.window.pid,
                                                                    windowID: target.window.windowID)
            guard let self, !Task.isCancelled else { return }
            self.captureLanded(captured, for: target, token: token)
        }

        let timer = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            guard let self, self.generation == token, self.pending != nil else { return }
            self.hoverTimer = nil
            self.hoverDelayElapsed = true
            // Open now if there is anything real to show — the live capture or
            // the last thumbnail seen. Otherwise the capture opens it on arrival.
            if self.pendingCapture != nil
                || WindowPreviewCapture.lastThumbnail(for: target.window.windowID) != nil {
                self.openPending()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// Windows the bar lists after a snapshot update. A card whose window has
    /// gone — closed, or moved out of scope — closes with it.
    func windowsChanged(_ ids: Set<CGWindowID>) {
        if let pending, !ids.contains(pending.window.windowID) { cancelPending() }
        if let shown, !ids.contains(shown.window.windowID) { dismiss() }
    }

    func dismiss(animated: Bool = true) {
        cancelPending()
        dismissTimer?.invalidate()
        dismissTimer = nil
        captureTask?.cancel()
        captureTask = nil
        removeMonitors()
        generation &+= 1
        let token = generation

        guard shown != nil, let panel, panel.isVisible else {
            shown = nil
            return
        }
        shown = nil
        timeline?.cancel()
        guard animated, !reduceMotion else {
            panel.orderOut(nil)
            return
        }
        // Back up under the bar it came from, faster than it arrived.
        let start = panel.frame
        let startAlpha = panel.alphaValue
        timeline = PreviewPanelTimeline(duration: 0.14, screen: panel.screen, step: { [weak panel] t in
            let p = t * t
            panel?.setFrameOrigin(NSPoint(x: start.minX,
                                          y: start.minY + TilingBarPreviewLayout.tuck * 0.5 * p))
            panel?.alphaValue = startAlpha * (1 - p)
        }, completion: { [weak self, weak panel] finished in
            guard finished, let self, self.generation == token else { return }
            panel?.orderOut(nil)
        })
    }

    // MARK: Opening and switching

    private func cancelPending() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let p = pending {
            p.onCancel()
            captureTask?.cancel()
            captureTask = nil
        }
        pending = nil
        pendingCapture = nil
        hoverDelayElapsed = false
    }

    private func captureLanded(_ captured: CapturedWindow, for target: Target, token: Int) {
        let id = target.window.windowID
        let fallbackTitle = target.window.title.isEmpty ? nil : target.window.title
        let windowWithTitle = (captured.title != nil && !captured.title!.isEmpty)
            ? captured
            : CapturedWindow(id: captured.id, image: captured.image, title: fallbackTitle, bounds: captured.bounds)
        if let shown, shown.window.windowID == id, generation == token {
            updateImage(windowWithTitle)
        } else if let pending, pending.window.windowID == id, generation == token {
            pendingCapture = windowWithTitle
            if hoverDelayElapsed { openPending() }
        } else if shown != nil, generation == token {
            // A switch whose target had no cached thumbnail waits for this.
            present(target, window: windowWithTitle)
        }
    }

    private func openPending() {
        guard let target = pending else { return }
        let fallbackTitle = target.window.title.isEmpty ? nil : target.window.title
        let window = pendingCapture ?? cachedWindow(for: target)
            ?? CapturedWindow(id: target.window.windowID,
                              image: target.window.icon ?? NSImage(),
                              title: fallbackTitle, bounds: target.window.frame)
        hoverTimer?.invalidate()
        hoverTimer = nil
        pending = nil
        pendingCapture = nil
        hoverDelayElapsed = false
        present(target, window: window)
    }

    private func switchTo(_ target: Target) {
        captureTask?.cancel()
        generation &+= 1
        let token = generation
        if let cached = cachedWindow(for: target) {
            present(target, window: cached)
        }
        captureTask = Task { @MainActor [weak self] in
            let captured = await WindowPreviewCapture.captureWindow(pid: target.window.pid,
                                                                    windowID: target.window.windowID)
            guard let self, !Task.isCancelled else { return }
            self.captureLanded(captured, for: target, token: token)
        }
    }

    private func cachedWindow(for target: Target) -> CapturedWindow? {
        guard let image = WindowPreviewCapture.lastThumbnail(for: target.window.windowID) else { return nil }
        let title = target.window.title.isEmpty ? nil : target.window.title
        return CapturedWindow(id: target.window.windowID, image: image, title: title,
                              bounds: target.window.frame)
    }

    private func present(_ target: Target, window: CapturedWindow, morphFrom: NSRect? = nil) {
        buildPanelIfNeeded()
        guard let panel else { return }
        let wasShown = (shown != nil && panel.isVisible) || morphFrom != nil
        shown = target

        model.onSelect = { [weak self] in
            self?.dismiss()
            target.activate()
        }
        model.onClose = { [weak self] in
            guard let self else { return }
            self.dismiss()
            let pid = target.window.pid
            let winID = target.window.windowID
            Task {
                await WindowPreviewCapture.closeWindow(pid: pid, windowID: winID)
            }
        }
        model.onFullscreen = { [weak self] in
            self?.dismiss()
            let bounds = window.bounds
            Task {
                await WindowPreviewCapture.toggleFullscreen(pid: target.window.pid,
                                                            windowID: target.window.windowID, bounds: bounds)
            }
        }
        // A drag off the card is the shared window drag; a drop anywhere ends
        // this card, as it does the Dock's and the Notch's.
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.panelFrame = { [weak self] in self?.panel?.frame ?? .zero }

        let screen = NSScreen.screens.first { $0.frame.intersects(target.bar) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let maxThumbHeight = max(90, (screen.frame.height - target.bar.height) * 0.38)
        let thumbHeight = min(AppSettings.shared.dockPreviewThumbHeight, maxThumbHeight)

        let apply = {
            self.model.window = window
            self.model.appName = target.window.name
            self.model.appIcon = target.window.icon
            self.model.pid = target.window.pid
            self.model.thumbHeight = thumbHeight
            self.model.captionHeight = Self.captionHeight(for: window, appName: target.window.name,
                                                          thumbHeight: thumbHeight)
            if morphFrom == nil { self.model.contentOpacity = 1 }
        }

        if wasShown && morphFrom == nil {
            withAnimation(.easeOut(duration: 0.18)) { apply() }
        } else {
            apply()
        }

        let frame = computeFrame(for: window, target: target)
        if let morphFrom {
            animateMorph(from: morphFrom, to: frame, duration: 0.28)
        } else if wasShown {
            // The outgoing thumbnail cross-fades into the incoming one while
            // the card glides over to its new icon.
            animateFrame(to: frame, duration: 0.24)
        } else {
            dropIn(to: frame)
        }
    }

    /// A live capture replacing the cached thumbnail the card opened with.
    private func updateImage(_ window: CapturedWindow) {
        guard let shown, let panel else { return }
        guard timeline == nil else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            model.window = window
            model.captionHeight = Self.captionHeight(for: window, appName: shown.window.name,
                                                     thumbHeight: model.thumbHeight)
        }
        let frame = computeFrame(for: window, target: shown)
        if abs(frame.width - panel.frame.width) > 1 || abs(frame.height - panel.frame.height) > 1 {
            animateFrame(to: frame, duration: 0.2)
        }
    }

    private static func captionHeight(for window: CapturedWindow, appName: String,
                                      thumbHeight: CGFloat) -> CGFloat {
        let layout = TilingBarPreviewLayout.self
        let cardWidth = layout.thumbnailWidth(aspect: layout.aspect(of: window.image), height: thumbHeight)
            + layout.windowCardFrame * 2
        return layout.captionHeight(for: window, appName: appName, cardWidth: cardWidth)
    }

    /// Where the card sits: centred under its icon, hanging `gapBelowBar` below
    /// the bar, kept clear of the screen's sides. Sized from the layout alone —
    /// identity row, framed thumbnail and caption all have known heights — so
    /// nothing waits on SwiftUI to measure it.
    private func computeFrame(for window: CapturedWindow, target: Target) -> NSRect {
        let layout = TilingBarPreviewLayout.self
        let screen = NSScreen.screens.first { $0.frame.intersects(target.bar) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let cardWidth = layout.thumbnailWidth(aspect: layout.aspect(of: window.image), height: model.thumbHeight)
            + layout.windowCardFrame * 2
        let capHeight = Self.captionHeight(for: window, appName: target.window.name, thumbHeight: model.thumbHeight)
        let caption = capHeight > 0 ? layout.captionGap + capHeight : 0
        let size = NSSize(
            width: ceil(cardWidth + layout.padding * 2),
            height: ceil(layout.padding + layout.identityHeight + layout.identityGap
                + model.thumbHeight + layout.windowCardFrame * 2 + caption + layout.padding)
        )

        let x = min(max(target.icon.midX - size.width / 2, screen.frame.minX + layout.screenInset),
                    screen.frame.maxX - size.width - layout.screenInset)
        let y = target.bar.minY - layout.gapBelowBar - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Motion

    /// Slides out from under the bar and settles with a slight give, as if it
    /// had dropped from the icon.
    private func dropIn(to frame: NSRect) {
        guard let panel else { return }
        timeline?.cancel()
        model.contentOpacity = 1
        let tuck: CGFloat = (frame.maxX > 660) ? 0 : TilingBarPreviewLayout.tuck
        let start = frame.offsetBy(dx: 0, dy: tuck)
        panel.setFrame(start, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        guard !reduceMotion else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            return
        }
        timeline = PreviewPanelTimeline(duration: 0.3, screen: panel.screen, step: { [weak panel] t in
            guard let panel else { return }
            let p = t >= 1 ? 1 : Easing.spring(t)
            panel.setFrameOrigin(NSPoint(x: frame.minX, y: start.minY + (frame.minY - start.minY) * p))
            // Opaque well before it settles: the give at the end is for the
            // eye to catch, not something it should watch fade in through.
            panel.alphaValue = min(1, t / 0.4)
        }, completion: { [weak self] _ in
            self?.timeline = nil
        })
    }

    private func animateMorph(from start: NSRect, to target: NSRect, duration: CFTimeInterval) {
        guard let panel else { return }
        timeline?.cancel()
        panel.setFrame(start, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        model.contentOpacity = 0
        withAnimation(.easeOut(duration: 0.20)) {
            self.model.contentOpacity = 1
        }
        guard !reduceMotion else {
            panel.setFrame(target, display: true)
            return
        }
        let screen = panel.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let inset = TilingBarPreviewLayout.screenInset
        let maxTop = (shown?.bar.minY ?? (screen.maxY - 32)) - TilingBarPreviewLayout.gapBelowBar
        timeline = PreviewPanelTimeline(duration: duration, screen: panel.screen, step: { [weak panel] t in
            let p = Easing.outQuart(t)
            let curW = (start.width + (target.width - start.width) * p).rounded()
            let rawX = start.minX + (target.minX - start.minX) * p
            let clampedX = min(max(rawX, screen.minX + inset), screen.maxX - curW - inset).rounded()
            let curH = (start.height + (target.height - start.height) * p).rounded()
            let curY = (maxTop - curH).rounded()
            panel?.setFrame(NSRect(x: clampedX, y: curY, width: curW, height: curH), display: true)
        }, completion: { [weak self] _ in
            self?.timeline = nil
        })
    }

    private func animateFrame(to target: NSRect, duration: CFTimeInterval) {
        guard let panel else { return }
        timeline?.cancel()
        let start = panel.frame
        let startAlpha = panel.alphaValue
        guard !reduceMotion else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            return
        }
        timeline = PreviewPanelTimeline(duration: duration, screen: panel.screen, step: { [weak panel] t in
            let p = Easing.outQuart(t)
            panel?.setFrame(NSRect(x: start.minX + (target.minX - start.minX) * p,
                                   y: start.minY + (target.minY - start.minY) * p,
                                   width: start.width + (target.width - start.width) * p,
                                   height: start.height + (target.height - start.height) * p),
                            display: true)
            panel?.alphaValue = startAlpha + (1 - startAlpha) * p
        })
    }

    // MARK: Pointer tracking

    /// The card, its icon, and the strip joining them, so moving straight down
    /// from an icon never crosses a gap that counts as leaving.
    private func pointerIsInside() -> Bool {
        guard let shown, let panel, panel.isVisible else { return false }
        let point = NSEvent.mouseLocation
        let card = panel.frame.insetBy(dx: -6, dy: -6)
        let bridgeMinY = min(card.maxY - 4, shown.bar.minY - 2)
        let bridgeMaxY = max(card.maxY + 4, shown.bar.maxY + 2)
        let bridgeMinX = min(card.minX, shown.icon.minX) - 4
        let bridgeMaxX = max(card.maxX, shown.icon.maxX) + 4
        let bridge = CGRect(x: bridgeMinX,
                            y: bridgeMinY,
                            width: bridgeMaxX - bridgeMinX,
                            height: bridgeMaxY - bridgeMinY)
        return card.contains(point) || bridge.contains(point)
            || shown.icon.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func scheduleDismissCheck() {
        guard dismissTimer == nil else { return }
        let timer = Timer(timeInterval: Self.dismissGrace, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dismissTimer = nil
            guard !WindowPreviewDragController.shared.isDragging else { return }
            if !self.pointerIsInside() { self.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let moved: () -> Void = { [weak self] in self?.pointerMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in moved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            moved()
            return event
        }) {
            monitors.append(m)
        }
        let clicked: () -> Void = { [weak self] in self?.pointerClicked() }
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { _ in clicked() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { event in
            clicked()
            return event
        }) {
            monitors.append(m)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func pointerMoved() {
        guard !WindowPreviewDragController.shared.isDragging else { return }
        if shown != nil {
            if pointerIsInside() {
                dismissTimer?.invalidate()
                dismissTimer = nil
            } else {
                scheduleDismissCheck()
            }
        } else if let pending {
            // Icon column spans full bar height; generous padding ensures subtle mouse motion
            // does not cancel hover intent while resting on an icon.
            let hitRect = pending.icon.insetBy(dx: -8, dy: -6)
            if !hitRect.contains(NSEvent.mouseLocation) {
                // Left the icon column before intent was established.
                cancelPending()
                removeMonitors()
            }
        }
    }

    private func pointerClicked() {
        guard shown != nil else {
            cancelPending()
            return
        }
        // Clicks on the card are the card's own; anything else closes it —
        // including a click on a bar icon, which activates that window instead.
        guard let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }

    // MARK: Panel

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: TilingBarPreviewView(model: model))
        // Sized by this controller only, or the hosting view pushes its own
        // size onto the window mid-animation.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = view
        p.isFloatingPanel = true
        // Beneath the bar (status-bar level) and its black backdrop (level 23),
        // above ordinary windows and the Dock. The drop-in starts tucked under
        // the bar, so the card slides out from behind it instead of fading in
        // over it.
        p.level = NSWindow.Level(rawValue: 22)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel = p
        hosting = view
    }
}
