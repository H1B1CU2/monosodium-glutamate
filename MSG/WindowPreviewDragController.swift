import AppKit
import ApplicationServices
import SwiftUI

// MARK: - PreviewPanelTimeline

/// One short panel animation, driven by the display's own refresh and reading
/// progress from the clock rather than counting frames. Timer plus time-based
/// progress is this project's animation pattern (see Indicator.swift);
/// `TilingDisplayClock` supplies ProMotion timing where the display has it.
///
/// `completion` runs exactly once — `true` when the timeline reached its end,
/// `false` when it was cancelled — so a caller awaiting it can never hang.
@available(macOS 14.0, *)
final class PreviewPanelTimeline {
    private var clock: TilingDisplayClock?
    private let began = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let step: (CGFloat) -> Void
    private var completion: ((Bool) -> Void)?
    private var ended = false

    init(duration: CFTimeInterval, screen: NSScreen?,
         step: @escaping (CGFloat) -> Void,
         completion: ((Bool) -> Void)? = nil) {
        self.duration = max(0.001, duration)
        self.step = step
        self.completion = completion
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            step(1)
            end(finished: true)
            return
        }
        clock = TilingDisplayClock(screen: screen) { [weak self] in self?.tick() }
        tick()
    }

    private func tick() {
        guard !ended else { return }
        let raw = min(1, CGFloat((CACurrentMediaTime() - began) / duration))
        step(raw)
        if raw >= 1 { end(finished: true) }
    }

    func cancel() { end(finished: false) }

    private func end(finished: Bool) {
        guard !ended else { return }
        ended = true
        clock?.invalidate()
        clock = nil
        let done = completion
        completion = nil
        done?(finished)
    }
}

// MARK: - Ghost

/// What the carried card draws.
///
/// An observable model, not a fresh root view per event. The previous ghost
/// rebuilt its SwiftUI tree, re-measured it and resized its panel on every
/// mouse-dragged event — display-rate layout on the main thread for a card
/// that only changes when it crosses into or out of its source panel. The
/// resize was also visible: the hint text changed width as the card left the
/// panel, the panel grew from its origin, and the card slid out from under
/// the pointer.
@available(macOS 14.0, *)
private final class WindowDragGhostModel: ObservableObject {
    @Published var image = NSImage()
    @Published var appIcon: NSImage?
    @Published var cardSize = CGSize(width: 200, height: 130)
    /// False for the first frame of a pick-up, so the lift springs from the
    /// card's resting size instead of appearing already raised.
    @Published var lifted = false
    @Published var isOverDeskspace = false
    /// The Desktop a release would send the window to, when the card is over
    /// one rather than over the desktop itself.
    @Published var dropTargetLabel: String?
}

@available(macOS 14.0, *)
private enum WindowDragGhostMetrics {
    /// Clear space around the card for its shadow and lifted scale. Fixed, so
    /// the card never moves inside its panel and the grabbed point stays
    /// exactly under the pointer.
    static let margin: CGFloat = 30
    /// Room below the card for the hint capsule.
    static let captionReserve: CGFloat = 34
    static let cardRadius: CGFloat = 10
    static let liftedScale: CGFloat = 1.035
    static let deskScale: CGFloat = 1.06

    static func panelSize(for card: CGSize) -> CGSize {
        CGSize(width: card.width + margin * 2,
               height: card.height + margin * 2 + captionReserve)
    }

    /// The card's origin inside the panel, in the panel's bottom-left space.
    static var cardOffset: CGPoint { CGPoint(x: margin, y: margin + captionReserve) }

    static func scale(lifted: Bool, overDesk: Bool) -> CGFloat {
        overDesk ? deskScale : (lifted ? liftedScale : 1)
    }
}

@available(macOS 14.0, *)
private struct WindowDragGhostView: View {
    @ObservedObject var model: WindowDragGhostModel

    var body: some View {
        let m = WindowDragGhostMetrics.self
        let card = model.cardSize
        let scale = m.scale(lifted: model.lifted, overDesk: model.isOverDeskspace)
        let shape = RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)

        ZStack(alignment: .topLeading) {
            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: card.width, height: card.height)
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(model.isOverDeskspace ? Color.accentColor : Color.white.opacity(0.28),
                                       lineWidth: model.isOverDeskspace ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .offset(x: 7, y: -7)
                    }
                }
                // The shadow is what sells the lift: it spreads and drops as
                // the card rises, which scale alone never reads as.
                .shadow(color: .black.opacity(model.lifted ? (model.isOverDeskspace ? 0.42 : 0.32) : 0.12),
                        radius: model.lifted ? (model.isOverDeskspace ? 20 : 14) : 4,
                        y: model.lifted ? (model.isOverDeskspace ? 10 : 6) : 1)
                .scaleEffect(scale)
                .offset(x: m.margin, y: m.margin)

            hint
                .frame(width: card.width + m.margin * 2)
                // Rides the card's scaled bottom edge, so the capsule never
                // overlaps a card that has grown.
                .offset(y: m.margin + card.height * (1 + scale) / 2 + 8)
                .opacity(model.lifted ? 1 : 0)
        }
        .frame(width: card.width + m.margin * 2,
               height: card.height + m.margin * 2 + m.captionReserve,
               alignment: .topLeading)
    }

    private var hintSymbol: String {
        if model.dropTargetLabel != nil { return "rectangle.on.rectangle" }
        return model.isOverDeskspace ? "arrow.down.to.line" : "hand.draw.fill"
    }

    private var hintText: String {
        if let label = model.dropTargetLabel { return "Release to move to \(label)" }
        return model.isOverDeskspace ? "Release to move here" : "Drag to Deskspace"
    }

    private var hint: some View {
        HStack(spacing: 5) {
            Image(systemName: hintSymbol)
                .font(.system(size: 10, weight: .bold))
            Text(hintText)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(model.isOverDeskspace ? 0.78 : 0.58)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
    }
}

// MARK: - Drop targets

/// A Desktop a carried window can be released onto without switching to it.
struct WindowDropTarget: Equatable {
    /// 0 when `newSpaceDisplayUUID` is set: the Space doesn't exist yet.
    let spaceID: UInt64
    /// Names the Desktop in the ghost's hint, e.g. "Desktop 2".
    let label: String
    /// Set for the Desktop strip's plus tile: releasing here adds a Desktop
    /// on this display and moves the window onto it.
    var newSpaceDisplayUUID: String? = nil
    /// Screen rect the dropped card flies into (the plus tile), if any.
    var landingRect: CGRect? = nil
}

/// A surface other than the desktop under the pointer that accepts a carried
/// window — the tiling bar's space indicator and its Desktop preview.
///
/// Consulted on every drag event, so answers must stay cheap and main-thread.
@available(macOS 14.0, *)
protocol WindowDropTargetProvider: AnyObject {
    /// The card moved; `point` is the pointer on screen. Runs before
    /// `windowDropTarget(at:windowID:)` for the same event, so a provider can
    /// open a surface there that the hit test then finds.
    func windowDragMoved(to point: NSPoint, windowID: CGWindowID)
    /// The Desktop a release at `point` would move `windowID` to, if any.
    func windowDropTarget(at point: NSPoint, windowID: CGWindowID) -> WindowDropTarget?
    /// The drag is over: dropped on `target`, or nil for a desktop drop or cancel.
    func windowDragEnded(droppedOn target: WindowDropTarget?)
    /// A drop onto `target` finished; `moved` is WindowServer's verdict.
    func windowMoved(_ windowID: CGWindowID, to target: WindowDropTarget, moved: Bool)
    /// Starts adding the Desktop a `newSpaceDisplayUUID` target asks for.
    /// True if this provider took it on.
    func windowDropCreateSpace(for target: WindowDropTarget) -> Bool
}

@available(macOS 14.0, *)
extension WindowDropTargetProvider {
    func windowDropCreateSpace(for target: WindowDropTarget) -> Bool { false }
}

// MARK: - WindowPreviewDragController

@available(macOS 14.0, *)
final class WindowPreviewDragController {
    static let shared = WindowPreviewDragController()

    private struct WeakProvider { weak var value: WindowDropTargetProvider? }
    private var providers: [WeakProvider] = []

    func registerDropTargetProvider(_ provider: WindowDropTargetProvider) {
        providers.removeAll { $0.value == nil || $0.value === provider }
        providers.append(WeakProvider(value: provider))
    }

    private var liveProviders: [WindowDropTargetProvider] { providers.compactMap(\.value) }

    private func dropTarget(at point: NSPoint) -> WindowDropTarget? {
        guard let id = currentWindow?.id, id != 0 else { return nil }
        for provider in liveProviders {
            if let target = provider.windowDropTarget(at: point, windowID: id) { return target }
        }
        return nil
    }

    private var ghostPanel: NSPanel?
    private var ghostHosting: NSHostingView<WindowDragGhostView>?
    private let model = WindowDragGhostModel()

    private(set) var isDragging = false
    private var currentWindow: CapturedWindow?
    private var currentPID: pid_t = 0
    private var cardSize: CGSize = .zero
    /// Where the pointer took hold of the card, from the card's bottom-left.
    private var grabOffset: CGPoint = .zero
    /// The card's rect on screen when it was picked up; a cancel returns here.
    private var pickupRect: CGRect = .zero
    private var sourcePanelFrame: CGRect = .zero
    private var onDismissSource: (() -> Void)?
    private var onFinish: ((Bool) -> Void)?
    private var presentationGeneration = 0
    private var animation: PreviewPanelTimeline?

    private var localDragMonitor: Any?
    private var localUpMonitor: Any?
    private var globalDragMonitor: Any?
    private var globalUpMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private init() {}

    // MARK: - Drag Lifecycle

    /// Begins a window preview drag operation from a preview card.
    ///
    /// `onFinish` is told how the drag ended — `true` for a drop onto the
    /// deskspace, `false` for a cancel — so a source that dimmed its card while
    /// it was out can restore it as the card flies back.
    func beginDrag(
        window: CapturedWindow,
        pid: pid_t,
        appName: String,
        appIcon: NSImage?,
        cardFrameOnScreen: CGRect,
        sourcePanelFrame: CGRect,
        startMouseLocation: NSPoint,
        onDismissSource: @escaping () -> Void,
        onFinish: ((Bool) -> Void)? = nil
    ) {
        guard !isDragging else { return }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        animation?.cancel()
        animation = nil

        isDragging = true
        currentWindow = window
        currentPID = pid
        self.sourcePanelFrame = sourcePanelFrame
        self.onDismissSource = onDismissSource
        self.onFinish = onFinish

        // Start exactly where the thumbnail already is. The old ghost placed
        // its panel origin at the card's corner, but the card sat inside the
        // panel below a caption and beside centring slack, so it appeared about
        // 30pt away from the thumbnail it was lifted off and jumped.
        let card = Self.thumbnailRect(imageSize: window.image.size, in: cardFrameOnScreen)
        cardSize = card.size
        pickupRect = card
        grabOffset = CGPoint(x: min(max(startMouseLocation.x - card.minX, 0), card.width),
                             y: min(max(startMouseLocation.y - card.minY, 0), card.height))

        buildGhostPanelIfNeeded()
        guard let ghostPanel, let ghostHosting else { return }
        model.image = window.image
        model.appIcon = appIcon
        model.cardSize = card.size
        model.lifted = false
        model.isOverDeskspace = false
        model.dropTargetLabel = nil

        // The panel may still hold the landing image from the previous drop.
        if ghostPanel.contentView !== ghostHosting { ghostPanel.contentView = ghostHosting }
        ghostPanel.hasShadow = false
        ghostPanel.setFrame(NSRect(origin: Self.panelOrigin(forCard: card.origin),
                                   size: WindowDragGhostMetrics.panelSize(for: card.size)),
                            display: true)
        ghostHosting.frame = NSRect(origin: .zero, size: ghostPanel.frame.size)
        ghostPanel.alphaValue = 1
        ghostPanel.orderFrontRegardless()

        // Lift on the next turn, once the resting card is on screen to spring from.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDragging, self.presentationGeneration == generation else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) { self.model.lifted = true }
        }

        installMonitors()
        updateDrag(currentMouseLocation: NSEvent.mouseLocation)
    }

    /// Follows the pointer one to one. No smoothing: any easing here is latency.
    func updateDrag(currentMouseLocation: NSPoint) {
        guard isDragging, let ghostPanel else { return }
        let origin = CGPoint(x: currentMouseLocation.x - grabOffset.x,
                             y: currentMouseLocation.y - grabOffset.y)
        ghostPanel.setFrameOrigin(Self.panelOrigin(forCard: origin))

        if let id = currentWindow?.id, id != 0 {
            liveProviders.forEach { $0.windowDragMoved(to: currentMouseLocation, windowID: id) }
        }
        let label = dropTarget(at: currentMouseLocation)?.label
        let over = label != nil || isOverDeskspace(currentMouseLocation)
        guard over != model.isOverDeskspace || label != model.dropTargetLabel else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
            model.isOverDeskspace = over
            model.dropTargetLabel = label
        }
        // A detent at the moment a release changes meaning, from "put it back"
        // to "move the window" — or from one destination to another.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Ends the drag operation when the mouse button is released.
    func endDrag(dropLocation: NSPoint) {
        guard isDragging else { return }
        removeMonitors()
        if let target = dropTarget(at: dropLocation), let window = currentWindow {
            let pid = currentPID
            let dismissSource = onDismissSource
            let finish = onFinish
            cleanup()
            liveProviders.forEach { $0.windowDragEnded(droppedOn: target) }
            dismissSource?()
            finish?(true)
            drop(window: window, pid: pid, onto: target)
            return
        }
        guard isOverDeskspace(dropLocation), let window = currentWindow else {
            cancelDrag()
            return
        }
        liveProviders.forEach { $0.windowDragEnded(droppedOn: nil) }
        let pid = currentPID
        let cardRect = presentedCardRect()
        let dismissSource = onDismissSource
        let finish = onFinish
        cleanup()
        dismissSource?()
        finish?(true)
        drop(window: window, pid: pid, at: dropLocation, from: cardRect)
    }

    /// Cancels the active drag: the card flies back to the slot it was lifted
    /// from and only disappears once it is there, so a cancel reads as "put
    /// back" rather than "vanished".
    func cancelDrag() {
        guard isDragging else { return }
        removeMonitors()
        liveProviders.forEach { $0.windowDragEnded(droppedOn: nil) }
        let finish = onFinish
        let home = pickupRect.origin
        let startOrigin = ghostPanel.map {
            CGPoint(x: $0.frame.minX + WindowDragGhostMetrics.cardOffset.x,
                    y: $0.frame.minY + WindowDragGhostMetrics.cardOffset.y)
        } ?? home
        cleanup()
        presentationGeneration &+= 1
        let generation = presentationGeneration

        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            model.lifted = false
            model.isOverDeskspace = false
            model.dropTargetLabel = nil
        }
        guard let panel = ghostPanel, !reduceMotion else {
            ghostPanel?.orderOut(nil)
            finish?(false)
            return
        }

        animation?.cancel()
        var handedBack = false
        animation = PreviewPanelTimeline(duration: 0.28, screen: panel.screen, step: { [weak panel] t in
            guard let panel else { return }
            let p = Easing.outQuart(t)
            let origin = CGPoint(x: startOrigin.x + (home.x - startOrigin.x) * p,
                                 y: startOrigin.y + (home.y - startOrigin.y) * p)
            panel.setFrameOrigin(Self.panelOrigin(forCard: origin))
            // Nearly home: give the slot back so the source card fades up
            // under the ghost as the ghost fades out — a cross-fade, never a
            // moment with two cards or none.
            if t >= 0.72 {
                if !handedBack { handedBack = true; finish?(false) }
                panel.alphaValue = max(0, 1 - (t - 0.72) / 0.28)
            }
        }, completion: { [weak self, weak panel] _ in
            if !handedBack { finish?(false) }
            guard let self, self.presentationGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    private func cleanup() {
        isDragging = false
        currentWindow = nil
        currentPID = 0
        onDismissSource = nil
        onFinish = nil
    }

    private func isOverDeskspace(_ point: NSPoint) -> Bool {
        !sourcePanelFrame.insetBy(dx: -8, dy: -8).contains(point)
    }

    // MARK: - Geometry

    /// The thumbnail inside the rect a source card reported: its own aspect,
    /// as wide as the rect allows, top-aligned — every source draws its image
    /// at the top of the card with any caption beneath.
    private static func thumbnailRect(imageSize: CGSize, in card: CGRect) -> CGRect {
        let minimum = CGSize(width: 80, height: 50)
        guard imageSize.width > 0, imageSize.height > 0, card.width > 0, card.height > 0 else {
            return CGRect(origin: card.origin, size: CGSize(width: max(card.width, minimum.width),
                                                            height: max(card.height, minimum.height)))
        }
        let aspect = imageSize.width / imageSize.height
        var width = card.width
        var height = width / aspect
        if height > card.height {
            height = card.height
            width = height * aspect
        }
        width = max(width, minimum.width)
        height = max(height, minimum.height)
        return CGRect(x: card.midX - width / 2, y: card.maxY - height, width: width, height: height)
    }

    private static func panelOrigin(forCard origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x - WindowDragGhostMetrics.cardOffset.x,
                y: origin.y - WindowDragGhostMetrics.cardOffset.y)
    }

    /// The card's rect as drawn, lifted scale included, so the landing image
    /// that takes over from it starts at exactly that size rather than
    /// visibly shrinking on its first frame.
    private func presentedCardRect() -> CGRect {
        guard let panel = ghostPanel else { return pickupRect }
        let offset = WindowDragGhostMetrics.cardOffset
        let base = CGRect(x: panel.frame.minX + offset.x, y: panel.frame.minY + offset.y,
                          width: cardSize.width, height: cardSize.height)
        let s = WindowDragGhostMetrics.scale(lifted: model.lifted, overDesk: model.isOverDeskspace)
        return base.insetBy(dx: -base.width * (s - 1) / 2, dy: -base.height * (s - 1) / 2)
    }

    // MARK: - Ghost presentation

    /// Fades the ghost out, optionally setting it down (unlifting) as it goes.
    /// Ignored if another drag has claimed the ghost since `generation`.
    private func fadeGhostOut(duration: TimeInterval = 0.14, generation: Int, settle: Bool = false) {
        guard generation == presentationGeneration, let panel = ghostPanel, panel.isVisible else { return }
        animation?.cancel()
        if settle, panel.contentView === ghostHosting {
            withAnimation(.easeOut(duration: duration)) {
                model.lifted = false
                model.isOverDeskspace = false
                model.dropTargetLabel = nil
            }
        }
        guard !reduceMotion else {
            panel.orderOut(nil)
            return
        }
        let startAlpha = panel.alphaValue
        animation = PreviewPanelTimeline(duration: duration, screen: panel.screen, step: { [weak panel] t in
            panel?.alphaValue = startAlpha * (1 - t * t)
        }, completion: { [weak self, weak panel] finished in
            guard finished, let self, self.presentationGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    /// Flies the dropped card into `landing` (the plus tile) and shrinks it
    /// away there, so dropping onto a Desktop that doesn't exist yet reads as
    /// the window going *into* the tile rather than vanishing where it was let go.
    private func absorbGhost(image: NSImage, from cardRect: CGRect, into landing: CGRect, generation: Int) {
        guard generation == presentationGeneration, let panel = ghostPanel else { return }
        animation?.cancel()
        guard !reduceMotion else {
            panel.orderOut(nil)
            return
        }

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: cardRect.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = WindowDragGhostMetrics.cardRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        panel.setFrame(cardRect, display: false)
        panel.contentView = imageView
        panel.hasShadow = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Ends as a sliver in the middle of the tile, keeping the card's shape.
        let endW = landing.width * 0.5
        let endH = cardRect.width > 0 ? endW * cardRect.height / cardRect.width : endW
        let end = CGRect(x: landing.midX - endW / 2, y: landing.midY - endH / 2, width: endW, height: endH)
        animation = PreviewPanelTimeline(duration: 0.32, screen: panel.screen, step: { [weak panel] t in
            let p = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            panel?.setFrame(NSRect(x: cardRect.minX + (end.minX - cardRect.minX) * p,
                                   y: cardRect.minY + (end.minY - cardRect.minY) * p,
                                   width: cardRect.width + (end.width - cardRect.width) * p,
                                   height: cardRect.height + (end.height - cardRect.height) * p),
                            display: true)
            // Fades over the last stretch, as it disappears into the tile.
            panel?.alphaValue = t < 0.6 ? 1 : max(0, 1 - (t - 0.6) / 0.4)
        }, completion: { [weak self, weak panel] _ in
            guard let self, self.presentationGeneration == generation else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    /// Grows the dropped card into the frame the window is about to occupy,
    /// before WindowServer moves the real window. The expanded image then stays
    /// as a cover while the cross-Space move settles.
    @MainActor
    private func animateCrossSpaceLanding(image: NSImage, from cardRect: CGRect,
                                          to targetFrame: CGRect, generation: Int) async {
        guard generation == presentationGeneration, let panel = ghostPanel else { return }
        animation?.cancel()

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: cardRect.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = WindowDragGhostMetrics.cardRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]

        // Exactly the rect the card occupied on its last frame. The previous
        // version stretched the image over the whole ghost panel — shadow
        // margin and hint capsule included — so the landing began with a
        // distorted jump before it had moved at all.
        panel.setFrame(cardRect, display: false)
        panel.contentView = imageView
        panel.hasShadow = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard !reduceMotion else {
            panel.setFrame(targetFrame, display: true)
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animation = PreviewPanelTimeline(duration: 0.34, screen: panel.screen, step: { [weak panel] t in
                // Ease in and out: the card leaves the pointer gently, travels,
                // and settles into the window's frame without overshooting it —
                // a window frame that bounces past its edges reads as broken.
                let p = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                panel?.setFrame(NSRect(x: cardRect.minX + (targetFrame.minX - cardRect.minX) * p,
                                       y: cardRect.minY + (targetFrame.minY - cardRect.minY) * p,
                                       width: cardRect.width + (targetFrame.width - cardRect.width) * p,
                                       height: cardRect.height + (targetFrame.height - cardRect.height) * p),
                                display: true)
            }, completion: { [weak panel] _ in
                panel?.invalidateShadow()
                continuation.resume()
            })
        }
    }

    private func buildGhostPanelIfNeeded() {
        guard ghostPanel == nil else { return }
        let hosting = NSHostingView(rootView: WindowDragGhostView(model: model))
        // Sized by the controller only. Left on, the hosting view pushes
        // constraints onto the window and fights every frame this class sets.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = false // Shadow is rendered by SwiftUI for continuous control
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting
        ghostPanel = p
        ghostHosting = hosting
    }

    // MARK: - Event Monitors

    private func installMonitors() {
        removeMonitors()

        // Local monitor (events directed at MSG)
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.updateDrag(currentMouseLocation: NSEvent.mouseLocation)
            return event
        }

        localUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.endDrag(dropLocation: NSEvent.mouseLocation)
            return event
        }

        // Global monitor (events occurring while cursor is over other apps / desktop)
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.updateDrag(currentMouseLocation: NSEvent.mouseLocation)
        }

        globalUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.endDrag(dropLocation: NSEvent.mouseLocation)
        }

        // Escape cancels. MSG is almost never the active app while a preview
        // is up, so the local monitor alone never saw the key.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelDrag()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.cancelDrag() }
        }
    }

    private func removeMonitors() {
        if let m = localDragMonitor { NSEvent.removeMonitor(m); localDragMonitor = nil }
        if let m = localUpMonitor { NSEvent.removeMonitor(m); localUpMonitor = nil }
        if let m = globalDragMonitor { NSEvent.removeMonitor(m); globalDragMonitor = nil }
        if let m = globalUpMonitor { NSEvent.removeMonitor(m); globalUpMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    // MARK: - Deskspace Drop Action

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard
              AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    @discardableResult
    private func setWindowPosition(_ point: CGPoint, for window: AXUIElement) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// AX does not provide implicit animation, so interpolate the concrete
    /// window position after it has arrived on the visible Space.
    ///
    /// Time-based, not a fixed frame count. An AX position write is synchronous
    /// IPC into the target app and takes anywhere from about 1ms to well over
    /// 30ms. Fourteen steps with a sleep after each stretched a slow app's move
    /// to twice its intended length and stuttered as it went; reading progress
    /// from the clock drops frames instead, and always lands on time.
    private func animateWindow(_ window: AXUIElement, from start: CGPoint, to end: CGPoint) async {
        let reduceMotion = await MainActor.run {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        guard !reduceMotion, hypot(end.x - start.x, end.y - start.y) > 1 else {
            setWindowPosition(end, for: window)
            return
        }

        let duration: CFTimeInterval = 0.28
        let began = CACurrentMediaTime()
        while !Task.isCancelled {
            let raw = min(1, CGFloat((CACurrentMediaTime() - began) / duration))
            let eased = Easing.outQuart(raw)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
            guard setWindowPosition(point, for: window) else { break }
            if raw >= 1 { break }
            do { try await Task.sleep(nanoseconds: 8_000_000) }
            catch { break }
        }
        setWindowPosition(end, for: window)
    }

    /// Executes the move/unminimize and focus of the target window onto the current deskspace.
    func performDeskspaceDrop(window: CapturedWindow, pid: pid_t, at screenPoint: NSPoint) {
        drop(window: window, pid: pid, at: screenPoint, from: nil)
    }

    private func drop(window: CapturedWindow, pid: pid_t, at screenPoint: NSPoint, from cardRect: CGRect?) {
        presentationGeneration &+= 1
        let generation = presentationGeneration

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
                ?? NSScreen.main ?? NSScreen.screens.first,
              let targetSpaceID = WindowPreviewCapture.currentManagedSpaceID(for: screen) else {
            NSLog("[MSG Window Drag] Cannot resolve the current Space at drop point %@",
                  NSStringFromPoint(screenPoint))
            fadeGhostOut(generation: generation, settle: true)
            return
        }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0

        // Window dimensions (fallback to sensible size if bounds were zero)
        let winSize = window.bounds.size.width > 50 && window.bounds.size.height > 50
            ? window.bounds.size
            : CGSize(width: 800, height: 600)

        // Compute top-left of window in Quartz/AX coordinates (top-left origin)
        var targetAX_X = screenPoint.x - (winSize.width / 2)
        var targetAX_Y = (primaryTop - screenPoint.y) - (winSize.height / 2)

        // Clamp inside screen visibleFrame so title bar is never inaccessible
        let screenAX_minX = screen.visibleFrame.minX
        let screenAX_maxX = screen.visibleFrame.maxX - winSize.width
        let screenAX_minY = primaryTop - screen.visibleFrame.maxY
        let screenAX_maxY = (primaryTop - screen.visibleFrame.minY) - winSize.height

        if screenAX_maxX >= screenAX_minX {
            targetAX_X = max(screenAX_minX + 8, min(targetAX_X, screenAX_maxX - 8))
        } else {
            targetAX_X = screenAX_minX + 8
        }

        if screenAX_maxY >= screenAX_minY {
            targetAX_Y = max(screenAX_minY + 8, min(targetAX_Y, screenAX_maxY - 8))
        } else {
            targetAX_Y = screenAX_minY + 8
        }

        let finalPos = CGPoint(x: targetAX_X, y: targetAX_Y)
        let finalCocoaFrame = CGRect(
            x: finalPos.x,
            y: primaryTop - finalPos.y - winSize.height,
            width: winSize.width,
            height: winSize.height
        )
        let isCrossSpaceDrop = !WindowPreviewCapture.window(window.id, isOnManagedSpace: targetSpaceID)
        let landingStart = cardRect ?? presentedCardRect()

        if !isCrossSpaceDrop {
            // The real window is already visible and will glide to the drop
            // point itself; the ghost only has to be set down.
            fadeGhostOut(duration: 0.16, generation: generation, settle: true)
        }

        Task {
            // For a cross-Space drop, finish the visible card movement first.
            // The real window remains entirely on its source Space until this
            // animation reaches the destination frame.
            if isCrossSpaceDrop {
                await animateCrossSpaceLanding(image: window.image, from: landingStart,
                                               to: finalCocoaFrame, generation: generation)
            }

            var axWin = WindowPreviewCapture.axWindow(pid: pid, windowID: window.id)
            if let axWin {
                guard await Self.prepareForSpaceMove(axWin) else { return }
            }

            // Space membership must change before activation. Otherwise the
            // native focus request switches the desktop back to the old Space.
            guard await WindowPreviewCapture.moveWindow(window.id, toManagedSpace: targetSpaceID) else {
                NSLog("[MSG Window Drag] WindowServer did not move window %u to Space %llu",
                      window.id, targetSpaceID)
                await MainActor.run { self.fadeGhostOut(duration: 0.2, generation: generation) }
                return
            }

            axWin = WindowPreviewCapture.axWindow(pid: pid, windowID: window.id) ?? axWin
            let animationStart = axWin.flatMap(windowPosition) ?? finalPos

            // Put a cross-Space window under the landing card before raising it.
            // Same-Space drops retain the direct AX movement animation.
            if isCrossSpaceDrop, let axWin {
                setWindowPosition(finalPos, for: axWin)
            }

            // Raise only after the verified reassignment, then animate the real
            // window into the requested drop position while it is visible.
            await WindowPreviewCapture.raiseWindow(
                pid: pid,
                windowID: window.id,
                fallbackBounds: CGRect(origin: finalPos, size: winSize)
            )

            if isCrossSpaceDrop {
                // A soft hand-off rather than a cut: the real window is under
                // the cover by now, so the cover dissolves into it.
                await MainActor.run { self.fadeGhostOut(duration: 0.18, generation: generation) }
            } else if let axWin = WindowPreviewCapture.axWindow(pid: pid, windowID: window.id) {
                await animateWindow(axWin, from: animationStart, to: finalPos)
            }
        }
    }

    /// Fullscreen windows own a dedicated Space and cannot be reassigned as
    /// ordinary windows. Leave fullscreen first, and unminimise, so the same
    /// concrete window moves instead of another one being created or selected.
    /// False only when the task was cancelled mid-wait.
    private static func prepareForSpaceMove(_ axWin: AXUIElement) async -> Bool {
        let fullScreenAttribute = "AXFullScreen" as CFString
        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, fullScreenAttribute, &fullScreenRef) == .success,
           (fullScreenRef as? Bool) == true {
            _ = AXUIElementSetAttributeValue(axWin, fullScreenAttribute, false as CFTypeRef)
            for _ in 0..<12 {
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return false }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, fullScreenAttribute, &value) != .success
                    || (value as? Bool) != true { break }
            }
        }

        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef)
        if (minRef as? Bool) == true {
            _ = AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        return true
    }

    /// A release over a Desktop in the tiling bar: the window moves to that
    /// Space and stays there. Nothing is raised — raising would switch the
    /// display to the Space the window just left for. The ghost sets down and
    /// fades where it was let go, and the Desktop preview, if open, shows the
    /// window arrive.
    private func drop(window: CapturedWindow, pid: pid_t, onto target: WindowDropTarget) {
        let cardRect = presentedCardRect()
        presentationGeneration &+= 1
        let generation = presentationGeneration
        if let landing = target.landingRect {
            absorbGhost(image: window.image, from: cardRect, into: landing, generation: generation)
        } else {
            fadeGhostOut(duration: 0.18, generation: generation, settle: true)
        }

        Task { @MainActor in
            var target = target
            if let displayUUID = target.newSpaceDisplayUUID {
                guard let created = await self.createSpace(displayUUID: displayUUID, for: target) else {
                    NSLog("[MSG Window Drag] New Desktop for window %u did not appear", window.id)
                    // Still report back, so the plus tile stops spinning.
                    self.liveProviders.forEach { $0.windowMoved(window.id, to: target, moved: false) }
                    return
                }
                // Keep the creation marker through the provider callback. The
                // Desktop strip must rebuild its groups for a newly added Space,
                // but an existing destination should wait for tiling to finish
                // before it recaptures the moved window.
                target = WindowDropTarget(
                    spaceID: created.id,
                    label: "Desktop \(created.number)",
                    newSpaceDisplayUUID: displayUUID
                )
            }
            // Finding the element can cost a brute-force sweep for a window on
            // another Space. Off the main actor, so the card's landing keeps
            // animating while that runs.
            let axWin = await Task.detached(priority: .userInitiated) {
                WindowPreviewCapture.axWindow(pid: pid, windowID: window.id)
            }.value
            if let axWin {
                guard await Self.prepareForSpaceMove(axWin) else { return }
            }
            let moved = await WindowPreviewCapture.moveWindow(window.id, toManagedSpace: target.spaceID)
            if !moved {
                NSLog("[MSG Window Drag] WindowServer did not move window %u to Space %llu",
                      window.id, target.spaceID)
            }
            liveProviders.forEach { $0.windowMoved(window.id, to: target, moved: moved) }
        }
    }
}

@available(macOS 14.0, *)
private extension WindowPreviewDragController {
    /// Has a provider add a Desktop on `displayUUID`, then waits for it to
    /// show up and for Mission Control — which adding drives — to close, so
    /// the move doesn't land while its animation still owns the Spaces.
    /// Returns the new Space and its 1-based number, or nil on timeout.
    func createSpace(displayUUID: String, for target: WindowDropTarget) async -> (id: UInt64, number: Int)? {
        guard let screen = NSScreen.screens.first(where: {
            $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
        }) else { return nil }
        let before = Set(WindowPreviewCapture.managedSpaces(for: screen).map(\.id))
        guard liveProviders.contains(where: { $0.windowDropCreateSpace(for: target) }) else { return nil }

        var created: (id: UInt64, number: Int)?
        for _ in 0..<50 {   // ~5s: Mission Control has to open first.
            let spaces = WindowPreviewCapture.managedSpaces(for: screen)
            if let index = spaces.firstIndex(where: { !before.contains($0.id) && !$0.isFullscreen }) {
                created = (spaces[index].id, index + 1)
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let created else { return nil }
        for _ in 0..<30 where MissionControlDetector.isActive() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Mission Control's close animation outlives its detector.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return created
    }
}

// MARK: - CardInteractionCatcher

/// Transparent overlay that turns left-clicks into window activation and drag gestures
/// into deskspace window drops.
@available(macOS 14.0, *)
struct CardInteractionCatcher: NSViewRepresentable {
    let onClick: () -> Void
    var onBeginDrag: ((NSPoint, CGRect) -> Void)? = nil
    var onDragChanged: ((NSPoint) -> Void)? = nil
    var onEndDrag: ((NSPoint) -> Void)? = nil
    var onCancelDrag: (() -> Void)? = nil
    var isHitExcluded: ((NSPoint, NSRect) -> Bool)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onClick = onClick
        v.onBeginDrag = onBeginDrag
        v.onDragChanged = onDragChanged
        v.onEndDrag = onEndDrag
        v.onCancelDrag = onCancelDrag
        v.isHitExcluded = isHitExcluded
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onClick = onClick
        nsView.onBeginDrag = onBeginDrag
        nsView.onDragChanged = onDragChanged
        nsView.onEndDrag = onEndDrag
        nsView.onCancelDrag = onCancelDrag
        nsView.isHitExcluded = isHitExcluded
    }

    final class CatcherView: NSView {
        var onClick: () -> Void = {}
        var onBeginDrag: ((NSPoint, CGRect) -> Void)?
        var onDragChanged: ((NSPoint) -> Void)?
        var onEndDrag: ((NSPoint) -> Void)?
        var onCancelDrag: (() -> Void)?
        var isHitExcluded: ((NSPoint, NSRect) -> Bool)?

        private var downLocation: NSPoint = .zero
        private var downScreenLocation: NSPoint = .zero
        private var isDragging = false
        private var isCandidate = false

        override func mouseDown(with event: NSEvent) {
            downLocation = event.locationInWindow
            downScreenLocation = NSEvent.mouseLocation
            isDragging = false
            isCandidate = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard isCandidate || isDragging else { return }
            let cur = event.locationInWindow
            let dist = hypot(cur.x - downLocation.x, cur.y - downLocation.y)
            if !isDragging && dist >= 6 {
                isDragging = true
                isCandidate = false
                let windowRect = convert(bounds, to: nil)
                let screenRect = window?.convertToScreen(windowRect)
                    ?? NSRect(origin: downScreenLocation, size: bounds.size)
                onBeginDrag?(downScreenLocation, screenRect)
            } else if isDragging {
                onDragChanged?(NSEvent.mouseLocation)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isDragging {
                isDragging = false
                if let onEndDrag {
                    onEndDrag(NSEvent.mouseLocation)
                } else {
                    WindowPreviewDragController.shared.endDrag(dropLocation: NSEvent.mouseLocation)
                }
            } else if isCandidate {
                isCandidate = false
                onClick()
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && isDragging {
                isDragging = false
                isCandidate = false
                if let onCancelDrag {
                    onCancelDrag()
                } else {
                    WindowPreviewDragController.shared.cancelDrag()
                }
                return
            }
            super.keyDown(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            // Right-click close feature removed per user request
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let eventType = NSApp.currentEvent?.type
            if eventType == .mouseMoved {
                return nil
            }
            if let excluded = isHitExcluded, excluded(point, bounds) {
                return nil
            }
            return super.hitTest(point)
        }
    }
}
