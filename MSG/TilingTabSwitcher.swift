import AppKit
import SwiftUI

// MARK: - Layout

/// Geometry of the swipe tab switcher: a vertical column of the tabbed
/// windows, built from the same `DockWindowCard` and panel as the Cmd-Tab
/// switcher and the control bar previews. Card and panel radii come from
/// `TilingBarPreviewLayout`.
@available(macOS 14.0, *)
enum TilingTabSwitcherLayout {
    /// A macOS window's own corner radius.
    static let windowCornerRadius: CGFloat = 12
    static let cardGap: CGFloat = 12
    static let defaultThumbHeight: CGFloat = 185
    static let cardPadding: CGFloat = 6
    static let cardRadius: CGFloat = 14
    static let stepTravel: CGFloat = 0.06
    /// Travel per tab once the column is on screen. Short, so the selection
    /// keeps up with the fingers rather than trailing them.
    static let uiStepTravel: CGFloat = 0.03
    static let transitionDuration: CFTimeInterval = 0.34
    static let fadeDuration: CFTimeInterval = 0.14
    /// Quick swipe threshold: if user finishes gesture within this window,
    /// switch tabs directly without showing the preview UI.
    static let quickSwipeThreshold: TimeInterval = 0.15
}

// MARK: - Model

@available(macOS 14.0, *)
private final class TilingTabSwitcherModel: ObservableObject {
    @Published var tabs: [TilingBarWindow] = []
    @Published var captures: [CGWindowID: CapturedWindow] = [:]
    @Published var selected = 0
    @Published var current = 0
    @Published var thumbHeight: CGFloat = 185
    @Published var stackFrame: CGRect = .zero
    @Published var viewportHeight: CGFloat = 800
    @Published var appeared = false

    /// A tab's live capture, else its last thumbnail, else a placeholder matching the tab's natural aspect.
    func window(for tab: TilingBarWindow) -> CapturedWindow {
        let cap = captures[tab.windowID]
        let title: String? = {
            if let capTitle = cap?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !capTitle.isEmpty {
                return capTitle
            }
            if !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return tab.title
            }
            return nil
        }()
        let img: NSImage = {
            if let capImg = cap?.image, capImg.size.width > 50, capImg.size.height > 50 {
                return capImg
            }
            if let last = WindowPreviewCapture.lastThumbnail(for: tab.windowID), last.size.width > 50, last.size.height > 50 {
                return last
            }
            return placeholderThumbnail(for: tab)
        }()
        return CapturedWindow(
            id: tab.windowID,
            image: img,
            title: title,
            bounds: cap?.bounds ?? tab.frame
        )
    }

    private func placeholderThumbnail(for tab: TilingBarWindow) -> NSImage {
        let a = aspect(for: tab)
        let baseHeight: CGFloat = 200
        let baseWidth = max(60, baseHeight * a)
        let size = NSSize(width: baseWidth.rounded(), height: baseHeight)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor(white: 0.16, alpha: 1.0).setFill()
        rect.fill()
        if let icon = tab.icon {
            let iconSize: CGFloat = min(48, min(size.width, size.height) * 0.4)
            let iconRect = NSRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            icon.draw(in: iconRect)
        }
        img.unlockFocus()
        return img
    }

    func aspect(for tab: TilingBarWindow) -> CGFloat {
        if let cap = captures[tab.windowID], cap.image.size.height > 50 && cap.image.size.width > 50 {
            return cap.image.size.width / cap.image.size.height
        }
        if let last = WindowPreviewCapture.lastThumbnail(for: tab.windowID), last.size.height > 50 && last.size.width > 50 {
            return last.size.width / last.size.height
        }
        if tab.frame.height > 0 && tab.frame.width > 0 {
            return tab.frame.width / tab.frame.height
        }
        if stackFrame.height > 0 && stackFrame.width > 0 {
            return stackFrame.width / stackFrame.height
        }
        return 1.4
    }

    func thumbWidth(for tab: TilingBarWindow) -> CGFloat {
        let a = aspect(for: tab)
        return TilingBarPreviewLayout.thumbnailWidth(aspect: a, height: thumbHeight)
    }

    var cardWidth: CGFloat {
        let widths = tabs.map { thumbWidth(for: $0) + TilingBarPreviewLayout.windowCardFrame * 2 }
        return max(170, widths.max() ?? 170)
    }

    func cellHeight(for tab: TilingBarWindow) -> CGFloat {
        let layout = TilingBarPreviewLayout.self
        let win = window(for: tab)
        let appName = tab.appName.isEmpty ? tab.name : tab.appName
        let capHeight = layout.captionHeight(for: win, appName: appName, cardWidth: cardWidth)
        let capSpace = capHeight > 0 ? (layout.captionGap + capHeight) : 0
        return layout.identityHeight + layout.identityGap + thumbHeight + layout.windowCardFrame * 2 + capSpace
    }

    var listHeight: CGFloat {
        let heights = tabs.map { cellHeight(for: $0) }
        let totalCells = heights.reduce(0, +)
        let totalGaps = max(0, CGFloat(tabs.count - 1)) * TilingTabSwitcherLayout.cardGap
        return totalCells + totalGaps
    }
}

// MARK: - View

@available(macOS 14.0, *)
private struct TilingTabSwitcherView: View {
    @ObservedObject var model: TilingTabSwitcherModel

    var body: some View {
        let layout = TilingBarPreviewLayout.self

        Group {
            if model.listHeight > model.viewportHeight {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { list }
                        .frame(height: model.viewportHeight)
                        .onAppear { proxy.scrollTo(model.selected, anchor: .center) }
                        .onChange(of: model.selected) { _, index in
                            // Quick, so the column tracks the fingers instead of easing after them.
                            withAnimation(.snappy(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
                        }
                }
            } else {
                list
            }
        }
        .padding(layout.padding)
        .modifier(PreviewPanelChrome(radius: layout.cardRadius))
        .fixedSize()
        // The switcher's entrance.
        .scaleEffect(model.appeared ? 1 : 0.94)
        .opacity(model.appeared ? 1 : 0)
    }

    private var list: some View {
        VStack(spacing: TilingTabSwitcherLayout.cardGap) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.windowID) { index, tab in
                cell(tab, index: index).id(index)
            }
        }
    }

    private func cell(_ tab: TilingBarWindow, index: Int) -> some View {
        let layout = TilingBarPreviewLayout.self
        let isSelected = index == model.selected
        let isCurrent = index == model.current
        let win = model.window(for: tab)
        let appName = tab.appName.isEmpty ? tab.name : tab.appName

        return VStack(alignment: .leading, spacing: layout.identityGap) {
            identityRow(tab: tab, appName: appName, isSelected: isSelected, isCurrent: isCurrent)

            DockWindowCard(
                window: win,
                appName: appName,
                height: model.thumbHeight,
                maxWidth: model.thumbHeight * layout.maxCardAspect,
                action: {},
                onClose: {},
                selected: isSelected,
                reservesCaption: false,
                captionHeight: nil,
                canHover: false,
                pid: tab.pid,
                appIcon: tab.icon,
                isHidden: PreviewHiddenStyle.isHidden(pid: tab.pid, windowID: tab.windowID)
            )
            .frame(width: model.cardWidth, alignment: .center)
        }
        .frame(width: model.cardWidth, alignment: .top)
    }

    private func identityRow(tab: TilingBarWindow, appName: String, isSelected: Bool, isCurrent: Bool) -> some View {
        let layout = TilingBarPreviewLayout.self
        return HStack(spacing: 6) {
            if let icon = tab.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .scaleEffect(isSelected ? 1.08 : 1.0)
                    .shadow(color: .black.opacity(isSelected ? 0.35 : 0.0), radius: isSelected ? 3 : 0, y: isSelected ? 1 : 0)
            }
            Text(appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .opacity(isSelected ? 1.0 : 0.72)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if isCurrent {
                Text("Current")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(isSelected ? 0.20 : 0.10)))
                    .fixedSize()
            }
        }
        .padding(.leading, 2)
        .frame(width: model.cardWidth, height: layout.identityHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

// MARK: - Controller

/// Flips through the tabbed windows of the display under the pointer with a
/// vertical trackpad swipe.
///
/// Fast swipes immediately switch windows with animation and no HUD popup.
/// Holding or pausing past the threshold brings up a clear preview column
/// with blurred window backdrop, large thumbnails, app name, and window title.
@available(macOS 14.0, *)
final class TilingTabSwitcher {
    /// Brings a tab forward for real, through the bar's own activation.
    var activate: ((TilingBarWindow, String) -> Void)?
    var isMissionControlActive: () -> Bool = { false }

    private struct Session {
        let group: TilingTabGroup
        /// The column the tabs share, in AppKit screen coordinates.
        let stackFrame: CGRect
        var selected: Int
        var lastOffset: CGFloat = 0
    }

    private var session: Session?
    private var panel: NSPanel?
    private var blurPanel: NSPanel?
    private var hosting: NSHostingView<TilingTabSwitcherView>?
    private let model = TilingTabSwitcherModel()
    private var captureTask: Task<Void, Never>?
    private var fade: PreviewPanelTimeline?
    private var generation = 0
    private let transition = TilingTabTransition()
    private var presentationWorkItem: DispatchWorkItem?
    private var isPresented = false
    private var isCursorHidden = false
    /// Full-size captures for the switch transition, which fills the whole
    /// tab column; the cards draw from card-sized copies in the model.
    private var fullImages: [CGWindowID: NSImage] = [:]

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func hideCursor() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        CGDisplayHideCursor(CGMainDisplayID())
        NSCursor.hide()
    }

    private func restoreCursor() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
    }

    deinit {
        restoreCursor()
    }

    // MARK: Swipe input

    func begin(_ group: TilingTabGroup) {
        guard let visible = Self.withoutHiddenTabs(group) else { return }
        let group = anchoredToPointer(visible)
        let current = group.tabs[group.currentIndex]
        // Only this column's tabs; windows from earlier swipes are released.
        fullImages = fullImages.filter { id, _ in group.tabs.contains { $0.windowID == id } }
        session = Session(group: group, stackFrame: current.frame, selected: group.currentIndex)
        isPresented = false
        capture(group)

        // Only present the preview UI if user holds or swipes beyond the quick swipe threshold
        presentationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let session = self.session else { return }
            self.isPresented = true
            self.present(session.group, stackFrame: session.stackFrame)
        }
        presentationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + TilingTabSwitcherLayout.quickSwipeThreshold, execute: item)
    }

    /// The tab this switcher activated a moment ago. The bar's snapshot —
    /// which says which tab is showing — refreshes on a poll, so a second quick
    /// swipe straight after the first still started from the old tab and just
    /// flipped back: with three tabs, only two were ever reachable.
    private var lastActivated: (windowID: CGWindowID, at: CFTimeInterval)?

    private func recentlyActivatedIndex(in group: TilingTabGroup, among candidates: [Int]) -> Int? {
        guard let lastActivated, CACurrentMediaTime() - lastActivated.at < 1.5 else { return nil }
        return candidates.first { group.tabs[$0].windowID == lastActivated.windowID }
    }

    /// Among the tabs under the pointer, the one frontmost in WindowServer's
    /// live z-order — current even when the bar's snapshot isn't yet.
    private static func frontmostIndex(in group: TilingTabGroup, among candidates: [Int]) -> Int? {
        guard candidates.count > 1,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let wanted = Dictionary(uniqueKeysWithValues: candidates.map { (group.tabs[$0].windowID, $0) })
        for info in list {
            if let id = info[kCGWindowNumber as String] as? CGWindowID, let index = wanted[id] { return index }
        }
        return nil
    }

    /// The group minus windows that are out of sight — hidden (⌘H), minimized,
    /// or ordered out — which a swipe shouldn't flip to. The current tab keeps
    /// its identity; nil when fewer than two tabs remain.
    private static func withoutHiddenTabs(_ group: TilingTabGroup) -> TilingTabGroup? {
        let current = group.tabs.indices.contains(group.currentIndex) ? group.tabs[group.currentIndex].windowID : nil
        let tabs = group.tabs.filter { !PreviewHiddenStyle.isHidden(pid: $0.pid, windowID: $0.windowID) }
        guard tabs.count > 1 else { return nil }
        let index = tabs.firstIndex { $0.windowID == current } ?? 0
        return TilingTabGroup(displayUUID: group.displayUUID, screen: group.screen, tabs: tabs, currentIndex: index)
    }

    /// The swipe works on the window under the pointer, not the focused one:
    /// with the focus in the left window and the pointer resting on the right
    /// column, the column was centred on — and flipped from — the left window.
    /// Tabs stacked in one column share its frame, so among the windows under
    /// the pointer the one showing wins, then the focused one.
    private func anchoredToPointer(_ group: TilingTabGroup) -> TilingTabGroup {
        let pointer = NSEvent.mouseLocation
        let under = group.tabs.indices.filter { group.tabs[$0].frame.contains(pointer) }
        guard let index = recentlyActivatedIndex(in: group, among: under)
                ?? Self.frontmostIndex(in: group, among: under)
                ?? under.first(where: { group.tabs[$0].isShownInLayout })
                ?? under.first(where: { group.tabs[$0].isFocused })
                ?? under.first,
              index != group.currentIndex else { return group }
        return TilingTabGroup(displayUUID: group.displayUUID, screen: group.screen,
                              tabs: group.tabs, currentIndex: index)
    }

    func change(_ offset: CGFloat) {
        guard var session else { return }
        session.lastOffset = offset
        let count = session.group.tabs.count
        let first = CGFloat(TrackpadSwipeMonitor.recognitionTravel)
        let magnitude = abs(offset)
        let travel = isPresented ? TilingTabSwitcherLayout.uiStepTravel : TilingTabSwitcherLayout.stepTravel
        let steps = magnitude < first ? 0 : 1 + Int((magnitude - first) / travel)
        // Natural direction:
        // Moving fingers DOWN on trackpad (offset < 0) advances down through the list (+steps)
        // Moving fingers UP on trackpad (offset > 0) moves back up through the list (-steps)
        let delta = (offset < 0) ? steps : -steps
        // A quick swipe wraps around — past the last tab comes the first — so
        // repeated flicks cycle through every tab. With the column on screen
        // it stops at the ends instead, where the user can see them.
        let raw = session.group.currentIndex + delta
        let index = isPresented ? max(0, min(count - 1, raw)) : (raw % count + count) % count
        let moved = index != session.selected
        session.selected = index
        self.session = session
        guard moved else { return }
        if isPresented {
            model.selected = index
            // A detent under the fingers for each tab passed.
            HapticFeedback.tick()
        }
    }

    func end() {
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        restoreCursor()
        guard let session else { return }
        self.session = nil
        if isPresented {
            hide()
        }
        isPresented = false

        let group = session.group
        guard session.selected != group.currentIndex, !isMissionControlActive() else { return }
        let from = group.tabs[group.currentIndex]
        let to = group.tabs[session.selected]
        if !reduceMotion {
            // Apple natural scrolling:
            // Swiping DOWN on trackpad (lastOffset < 0) pushes the animation UP.
            // Swiping UP on trackpad (lastOffset > 0) pushes the animation DOWN.
            let animateUp = session.lastOffset < 0 || (session.lastOffset == 0 && session.selected > group.currentIndex)

            let targetFrame = to.frame
            let transitionFrame = (targetFrame.width > 0 && targetFrame.height > 0) ? targetFrame : session.stackFrame
            transition.run(from: fullImages[from.windowID] ?? model.window(for: from).image,
                           to: fullImages[to.windowID] ?? model.window(for: to).image,
                           frame: transitionFrame, animateUp: animateUp, screen: group.screen)
        }
        lastActivated = (to.windowID, CACurrentMediaTime())
        activate?(to, group.displayUUID)
    }

    /// Tiling stopped mid-swipe.
    func cancel() {
        presentationWorkItem?.cancel()
        presentationWorkItem = nil
        restoreCursor()
        session = nil
        captureTask?.cancel()
        captureTask = nil
        if isPresented {
            hide()
        }
        isPresented = false
        blurPanel?.orderOut(nil)
    }

    // MARK: Presentation

    private func present(_ group: TilingTabGroup, stackFrame: CGRect) {
        hideCursor()
        buildPanelIfNeeded()
        buildBlurPanelIfNeeded()
        guard let panel else { return }
        generation &+= 1
        fade?.cancel()
        fade = nil

        let visible = group.screen.visibleFrame
        model.tabs = group.tabs
        model.current = group.currentIndex
        model.selected = group.currentIndex

        model.thumbHeight = TilingTabSwitcherLayout.defaultThumbHeight
        model.stackFrame = stackFrame
        model.viewportHeight = visible.height * 0.82
        model.captures = model.captures.filter { id, _ in group.tabs.contains { $0.windowID == id } }
        model.appeared = false

        // Show window blur backdrop
        if let blurPanel, stackFrame.width > 0, stackFrame.height > 0 {
            blurPanel.setFrame(stackFrame, display: true)
            blurPanel.alphaValue = 0
            blurPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                blurPanel.animator().alphaValue = 1
            }
        }

        panel.setFrame(frame(for: stackFrame, screen: group.screen), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // Next turn, so the entrance springs from its resting state.
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.session != nil else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.76)) { self.model.appeared = true }
        }
    }

    private func updatePanelFrame(session: Session) {
        guard let panel, panel.isVisible else { return }
        let targetFrame = frame(for: session.stackFrame, screen: session.group.screen)
        if abs(targetFrame.width - panel.frame.width) > 1 || abs(targetFrame.height - panel.frame.height) > 1 {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func hide() {
        restoreCursor()
        if let blurPanel, blurPanel.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = TilingTabSwitcherLayout.fadeDuration
                blurPanel.animator().alphaValue = 0
            }, completionHandler: { [weak blurPanel] in
                blurPanel?.orderOut(nil)
                blurPanel?.alphaValue = 1
            })
        }

        guard let panel, panel.isVisible else { return }
        generation &+= 1
        let token = generation
        withAnimation(.easeOut(duration: TilingTabSwitcherLayout.fadeDuration)) { model.appeared = false }
        guard !reduceMotion else {
            panel.orderOut(nil)
            return
        }
        fade?.cancel()
        fade = PreviewPanelTimeline(duration: TilingTabSwitcherLayout.fadeDuration, screen: panel.screen,
                                    step: { [weak panel] t in panel?.alphaValue = 1 - t },
                                    completion: { [weak self, weak panel] finished in
            guard finished, let self, self.generation == token else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    /// Centred on the tab column, kept inside the display's usable area.
    private func frame(for stackFrame: CGRect, screen: NSScreen) -> NSRect {
        let layout = TilingBarPreviewLayout.self
        let size = NSSize(width: ceil(model.cardWidth + layout.padding * 2),
                          height: ceil(min(model.listHeight, model.viewportHeight) + layout.padding * 2))
        let bounds = screen.visibleFrame.insetBy(dx: layout.screenInset, dy: layout.screenInset)
        let midX = (stackFrame.width > 0) ? stackFrame.midX : bounds.midX
        let midY = (stackFrame.height > 0) ? stackFrame.midY : bounds.midY
        let x = min(max(midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(midY - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Live captures, the showing tab and its neighbours first.
    private func capture(_ group: TilingTabGroup) {
        captureTask?.cancel()
        let count = group.tabs.count
        let order = group.tabs.indices.sorted {
            let a = min(abs($0 - group.currentIndex), count - abs($0 - group.currentIndex))
            let b = min(abs($1 - group.currentIndex), count - abs($1 - group.currentIndex))
            return a < b
        }
        captureTask = Task { @MainActor [weak self] in
            for index in order {
                let tab = group.tabs[index]
                let full = await WindowPreviewCapture.captureWindow(pid: tab.pid, windowID: tab.windowID)
                // Shrunk to card size before it reaches the list: a full
                // Retina frame per tab, landing mid-swipe, was redrawn and
                // scaled down on every step and made the column lag.
                let image = await Task.detached(priority: .userInitiated) {
                    Self.cardSized(full.image)
                }.value
                let captured = CapturedWindow(id: full.id, image: image, title: full.title, bounds: full.bounds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.fullImages[tab.windowID] = full.image
                self.model.captures[tab.windowID] = captured
                if let session = self.session {
                    self.updatePanelFrame(session: session)
                }
            }
        }
    }

    /// Longest edge of a card's picture, in pixels: twice the widest card.
    private static let cardPixels: CGFloat = 640

    private static func cardSized(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let fit = cardPixels / CGFloat(max(cg.width, cg.height, 1))
        guard fit < 1 else { return image }
        let width = max(1, Int(CGFloat(cg.width) * fit))
        let height = max(1, Int(CGFloat(cg.height) * fit))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return image }
        return NSImage(cgImage: small, size: image.size)
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: TilingTabSwitcherView(model: model))
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 480),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = view
        p.isFloatingPanel = true
        // Above windows, beneath the control bar.
        p.level = NSWindow.Level(rawValue: 22)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel = p
        hosting = view
    }

    private func buildBlurPanelIfNeeded() {
        guard blurPanel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Over the window being switched, directly underneath the switcher panel.
        p.level = NSWindow.Level(rawValue: 21)
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = TilingTabSwitcherLayout.windowCornerRadius
        effect.layer?.masksToBounds = true
        p.contentView = effect
        blurPanel = p
    }
}

// MARK: - Transition

/// The tab switch itself, played over the tab column: the chosen tab slides in
/// from the side the preview indicates while the old one lifts away and dims.
@available(macOS 14.0, *)
private final class TilingTabTransition {
    private var panel: NSPanel?
    private let container = CALayer()
    private let outgoing = CALayer()
    private let incoming = CALayer()
    private var timeline: PreviewPanelTimeline?
    private var generation = 0

    private static func cgImage(from image: NSImage) -> CGImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Ease-out close to a quartic: quick off the mark, long gentle landing.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)

    /// Played by Core Animation in the render server, not stepped from the
    /// main thread: the switch raises the real window and retiles as it
    /// starts, and that main-thread work used to drop the stepped frames and
    /// make the slide stutter.
    func run(from: NSImage, to: NSImage, frame: CGRect, animateUp: Bool, screen: NSScreen) {
        guard frame.width > 0, frame.height > 0,
              let fromImage = Self.cgImage(from: from),
              let toImage = Self.cgImage(from: to) else { return }
        buildPanelIfNeeded()
        guard let panel else { return }
        generation &+= 1
        let token = generation
        timeline?.cancel()
        timeline = nil

        let bounds = CGRect(origin: .zero, size: frame.size)
        // When animateUp is true (swipe down gesture), invert direction to -1 so
        // the transition visually travels upward.
        let direction: CGFloat = animateUp ? -1 : 1

        // The starting state, applied without animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [container, outgoing, incoming] { layer.removeAllAnimations() }
        container.frame = bounds
        container.opacity = 1
        outgoing.contents = fromImage
        incoming.contents = toImage
        outgoing.frame = bounds
        outgoing.opacity = 1
        incoming.frame = bounds.offsetBy(dx: 0, dy: -direction * bounds.height)
        CATransaction.commit()

        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // The slide: implicit animations from the state above.
        CATransaction.begin()
        CATransaction.setAnimationDuration(TilingTabSwitcherLayout.transitionDuration)
        CATransaction.setAnimationTimingFunction(Self.easeOut)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == token else { return }
            // Dissolve into the real window, which is up beneath by now.
            CATransaction.begin()
            CATransaction.setAnimationDuration(TilingTabSwitcherLayout.fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == token else { return }
                self.panel?.orderOut(nil)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.container.opacity = 1
                CATransaction.commit()
            }
            self.container.opacity = 0
            CATransaction.commit()
        }
        incoming.frame = bounds
        outgoing.frame = bounds.offsetBy(dx: 0, dy: direction * bounds.height * 0.35)
        outgoing.opacity = 0.4
        CATransaction.commit()
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        container.masksToBounds = true
        container.cornerRadius = TilingTabSwitcherLayout.windowCornerRadius
        container.cornerCurve = .continuous
        for layer in [outgoing, incoming] {
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            container.addSublayer(layer)
        }
        view.layer?.addSublayer(container)

        let p = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = view
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: 21)
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel = p
    }
}
