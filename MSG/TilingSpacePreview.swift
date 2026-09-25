import AppKit
import SwiftUI

// MARK: - Layout

/// Geometry of the space indicator's Desktop strip: one preview card per Desktop,
/// styled with the Notch preview's design language (.ultraThinMaterial, corner radius 26,
/// framed thumbnail, subtle hover lift and accent border), with a vertical divider
/// separating each deskspace.
@available(macOS 14.0, *)
enum TilingSpacePreviewLayout {
    static let panelPaddingHorizontal: CGFloat = 16
    static let panelPaddingVertical: CGFloat = 16
    static let panelRadius: CGFloat = 26

    /// Spacing between deskspace cards (no divider)
    static let cardSpacing: CGFloat = 12
    /// The slim "new Desktop" tile after the last card — Mission Control's
    /// plus, in the strip's own card frame.
    static let addTileWidth: CGFloat = 64

    /// Header geometry (Desktop 1, Current badge, count/icons)
    static let headerHeight: CGFloat = 20
    static let headerGap: CGFloat = 8

    /// Card frame & thumbnail
    static let cardFrame: CGFloat = 6
    static let innerRadius: CGFloat = 8
    static let outerRadius: CGFloat = 14

    /// Bottom apps row geometry (replaces app names at bottom)
    static let appIconSize: CGFloat = 20
    static let bottomHeight: CGFloat = 22
    static let bottomGap: CGFloat = 8

    /// Share of the screen height below the bar a thumbnail may take.
    static let maxScreenShare: CGFloat = 0.26
    static let thumbScale: CGFloat = 0.75
    static let maxWindows = 12

    static let coordinateSpace = "tilingSpaceStrip"
    /// `groupFrames` / `dropTarget` key for the new-Desktop plus tile.
    /// Desktop numbers start at 1, so 0 can't collide.
    static let newDesktopKey = 0
}

// MARK: - Cache

@available(macOS 14.0, *)
enum TilingSpacePreviewCache {
    static var captures: [UInt64: (stamp: CFTimeInterval, windows: [NotchWindowItem])] = [:]
    static var captureOrder: [UInt64] = []
    static let captureCacheLimit = 16
    static let captureFreshness: CFTimeInterval = 2.5

    static func cached(for spaceID: UInt64) -> [NotchWindowItem]? {
        guard let cached = captures[spaceID],
              CACurrentMediaTime() - cached.stamp < captureFreshness else { return nil }
        return cached.windows
    }

    static func remember(_ windows: [NotchWindowItem], for spaceID: UInt64) {
        captures[spaceID] = (CACurrentMediaTime(), windows)
        captureOrder.removeAll { $0 == spaceID }
        captureOrder.append(spaceID)
        while captureOrder.count > captureCacheLimit {
            captures.removeValue(forKey: captureOrder.removeFirst())
        }
    }

    static func remove(windowID: CGWindowID, on spaceID: UInt64) {
        guard var cached = captures[spaceID] else { return }
        cached.windows.removeAll { $0.id == windowID }
        captures[spaceID] = cached
    }
}

// MARK: - Model

@available(macOS 14.0, *)
struct SpaceTile: Identifiable {
    let number: Int
    let spaceID: UInt64
    let isFullscreen: Bool
    /// Front to back, as WindowServer orders them.
    var windows: [NotchWindowItem] = []
    /// False until this Desktop's first capture lands, so an empty group only
    /// says so once that is known.
    var loaded = false

    var id: UInt64 { spaceID }

    /// Mission Control names a fullscreen Space after its app.
    var name: String {
        if isFullscreen, let app = windows.first?.appName { return app }
        return "Desktop \(number)"
    }

    struct AppEntry: Identifiable {
        let name: String
        let icon: NSImage?
        var id: String { name }
    }

    /// Unique apps running on this desktop, in order of appearance
    var uniqueApps: [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        for w in windows {
            if !seen.contains(w.appName) {
                seen.insert(w.appName)
                result.append(AppEntry(name: w.appName, icon: w.appIcon))
            }
        }
        return result
    }
}

@available(macOS 14.0, *)
struct GroupFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

@available(macOS 14.0, *)
final class TilingSpacePreviewModel: ObservableObject {
    @Published var tiles: [SpaceTile] = []
    @Published var currentNumber: Int?
    /// The Desktop whose pill or card is hovered. Exactly ONE at a time.
    @Published var highlighted: Int?
    /// The Desktop a carried window would land on if released now.
    @Published var dropTarget: Int?
    @Published var thumbHeight: CGFloat = 105
    @Published var displayAspect: CGFloat = 1.6
    @Published var viewportWidth: CGFloat = 1200
    @Published var wallpaper: NSImage?
    @Published var screenBounds: CGRect = .zero
    @Published var menuBarHeight: CGFloat = 28
    @Published var contentOpacity: CGFloat = 1.0
    @Published var showAddButton: Bool = true
    /// The Desktop number a swipe is holding down to delete, if any.
    @Published var deleteHold: Int?
    /// 0…1 across that hold; animated linearly by the switcher.
    @Published var deleteProgress: CGFloat = 0
    /// A window was dropped on the plus tile and its Desktop is being added.
    @Published var isAddingDesktop = false
    /// The Desktop number picked up to reorder, if any.
    @Published var carried: Int?
    /// Horizontal offset of the currently carried card during mouse drag.
    @Published var carriedOffset: CGFloat = 0
    /// Whether a deskspace card is currently being dragged to reorder.
    @Published var isReordering: Bool = false
    var isGestureControlled: Bool = false

    /// Reorder drag tracking
    @Published var reorderTargetIndex: Int? = nil
    var reorderInitialIndex: Int? = nil
    private var reorderStartMouseX: CGFloat = 0

    /// Each deskspace card's frame in the strip's coordinates, for drop hit-testing.
    var groupFrames: [Int: CGRect] = [:]

    var onSelectDesktop: (Int) -> Void = { _ in }
    var onDeleteDesktop: (Int) -> Void = { _ in }
    var onAddDesktop: () -> Void = {}
    var onReorderDesktops: (([(from: Int, to: Int)], Int?) -> Void)? = nil
    var onSelectWindow: (NotchWindowItem) -> Void = { _ in }
    var onClose: (NotchWindowItem) -> Void = { _ in }
    var onFullscreen: (NotchWindowItem) -> Void = { _ in }
    var onCardDropped: () -> Void = {}
    var panelFrame: () -> CGRect = { .zero }

    func offsetForTile(at index: Int) -> CGFloat {
        guard isReordering, let initial = reorderInitialIndex, let target = reorderTargetIndex else {
            return 0
        }
        let slotWidth = cardWidth + TilingSpacePreviewLayout.cardSpacing

        if index == initial {
            return carriedOffset
        }

        if initial < target {
            if index > initial && index <= target {
                return -slotWidth
            }
        } else if target < initial {
            if index >= target && index < initial {
                return slotWidth
            }
        }
        return 0
    }

    func beginDeskspaceDrag(tile: SpaceTile, startMouse: NSPoint) {
        guard let initialIdx = tiles.firstIndex(where: { $0.spaceID == tile.spaceID }) else { return }
        guard !tile.isFullscreen, tiles.count > 1 else { return }

        isReordering = true
        carried = tile.number
        carriedOffset = 0
        reorderInitialIndex = initialIdx
        reorderTargetIndex = initialIdx
        reorderStartMouseX = startMouse.x

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func updateDeskspaceDrag(currentMouse: NSPoint) {
        guard isReordering, let initial = reorderInitialIndex, let currentTarget = reorderTargetIndex else { return }

        let rawDelta = currentMouse.x - reorderStartMouseX
        let slotWidth = cardWidth + TilingSpacePreviewLayout.cardSpacing

        // Valid range bounds (cannot cross fullscreen spaces)
        var lo = initial
        var hi = initial
        while lo > 0, !tiles[lo - 1].isFullscreen { lo -= 1 }
        while hi < tiles.count - 1, !tiles[hi + 1].isFullscreen { hi += 1 }

        let minDelta = CGFloat(lo - initial) * slotWidth
        let maxDelta = CGFloat(hi - initial) * slotWidth

        // Constrain visual movement within bounds with elastic rubberbanding
        if rawDelta < minDelta {
            let over = minDelta - rawDelta
            carriedOffset = minDelta - (over / (1.0 + over / 14.0))
        } else if rawDelta > maxDelta {
            let over = rawDelta - maxDelta
            carriedOffset = maxDelta + (over / (1.0 + over / 14.0))
        } else {
            carriedOffset = rawDelta
        }

        guard lo < hi else { return }

        let currentShift = currentTarget - initial
        // Hysteresis deadband (+/- 12% of slot width) to avoid jitter/tweaking out near slot boundaries
        let h: CGFloat = 0.12 * slotWidth
        let upperThreshold = (CGFloat(currentShift) + 0.5) * slotWidth + h
        let lowerThreshold = (CGFloat(currentShift) - 0.5) * slotWidth - h

        let slotShift: Int
        if rawDelta > upperThreshold {
            let steps = Int(((rawDelta - upperThreshold) / slotWidth).rounded(.down)) + 1
            slotShift = currentShift + steps
        } else if rawDelta < lowerThreshold {
            let steps = Int(((lowerThreshold - rawDelta) / slotWidth).rounded(.down)) + 1
            slotShift = currentShift - steps
        } else {
            slotShift = currentShift
        }

        let targetIndex = min(max(initial + slotShift, lo), hi)
        if targetIndex != currentTarget {
            reorderTargetIndex = targetIndex
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func endDeskspaceDrag(currentMouse: NSPoint) {
        guard isReordering, let initial = reorderInitialIndex, let target = reorderTargetIndex else { return }
        guard tiles.indices.contains(initial), tiles.indices.contains(target) else {
            cancelDeskspaceDrag()
            return
        }

        let didMove = (target != initial)
        let from1Based = initial + 1
        let to1Based = target + 1
        let current1Based = currentNumber

        if didMove {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                let moved = tiles.remove(at: initial)
                tiles.insert(moved, at: target)
                tiles = tiles.enumerated().map { idx, t in
                    SpaceTile(
                        number: idx + 1,
                        spaceID: t.spaceID,
                        isFullscreen: t.isFullscreen,
                        windows: t.windows,
                        loaded: t.loaded
                    )
                }
                carriedOffset = 0
                carried = nil
                reorderInitialIndex = nil
                reorderTargetIndex = nil
            }
            isReordering = false

            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

            let show: Int? = current1Based.map { cur in
                if cur == from1Based { return to1Based }
                if from1Based < to1Based, cur > from1Based, cur <= to1Based { return cur - 1 }
                if to1Based < from1Based, cur >= to1Based, cur < from1Based { return cur + 1 }
                return cur
            }
            if let show {
                currentNumber = show
            }

            onReorderDesktops?([(from: from1Based, to: to1Based)], show)
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                carriedOffset = 0
                carried = nil
                reorderInitialIndex = nil
                reorderTargetIndex = nil
            }
            isReordering = false
        }
    }

    func cancelDeskspaceDrag() {
        guard isReordering else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            carriedOffset = 0
            carried = nil
            reorderTargetIndex = reorderInitialIndex
        }
        isReordering = false
        reorderInitialIndex = nil
        reorderTargetIndex = nil
    }

    /// Width of the miniature desktop canvas
    var canvasWidth: CGFloat {
        (thumbHeight * displayAspect).rounded()
    }

    /// Total outer width of one deskspace card (canvas + 2 * cardFrame)
    var cardWidth: CGFloat {
        canvasWidth + TilingSpacePreviewLayout.cardFrame * 2
    }

    /// Outer height of the thumbnail container
    var thumbnailHeight: CGFloat {
        thumbHeight + TilingSpacePreviewLayout.cardFrame * 2
    }

    /// Total height of one deskspace card (header + gap + thumbnail + gap + bottom)
    var cardHeight: CGFloat {
        let l = TilingSpacePreviewLayout.self
        let header = l.headerHeight + l.headerGap
        let thumbnail = thumbnailHeight
        let bottom = l.bottomGap + l.bottomHeight
        return header + thumbnail + bottom
    }

    /// Entire row width including all cards, spacing, and panel padding
    var rowWidth: CGFloat {
        let count = CGFloat(tiles.count)
        guard count > 0 else { return 0 }
        let cards = count * cardWidth
        let spacing = max(0, count - 1) * TilingSpacePreviewLayout.cardSpacing
        let addTile = showAddButton ? (TilingSpacePreviewLayout.cardSpacing + TilingSpacePreviewLayout.addTileWidth) : 0
        return cards + spacing + addTile + TilingSpacePreviewLayout.panelPaddingHorizontal * 2
    }
}

// MARK: - View

@available(macOS 14.0, *)
struct DeskspaceCanvasView: View {
    let tile: SpaceTile
    let screenBounds: CGRect
    let menuBarHeight: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let wallpaper: NSImage?
    /// Off while a hold-to-delete countdown covers the canvas, so its label
    /// doesn't sit on top of this one.
    var showsEmptyState: Bool = true

    var body: some View {
        let workspaceHeight = max(100, screenBounds.height - menuBarHeight)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenBounds.height
        let workspaceQuartzRect = CGRect(
            x: screenBounds.minX,
            y: (primaryHeight - screenBounds.maxY) + menuBarHeight,
            width: max(1, screenBounds.width),
            height: max(1, workspaceHeight)
        )
        let scaleX = canvasWidth / workspaceQuartzRect.width
        let scaleY = canvasHeight / workspaceQuartzRect.height
        let menuBarRatio = screenBounds.height > 0 ? (menuBarHeight / screenBounds.height) : 0

        ZStack(alignment: .topLeading) {
            // Desktop background (wallpaper cropped to exclude menu bar at the top)
            if let wallpaper {
                GeometryReader { geo in
                    let cropTop = geo.size.height * (menuBarRatio / max(0.01, 1 - menuBarRatio))
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height + cropTop)
                        .offset(y: -cropTop)
                }
                .frame(width: canvasWidth, height: canvasHeight)
                .clipped()
            } else {
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.11)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // Empty state placeholder
            if tile.windows.isEmpty, showsEmptyState {
                if tile.loaded {
                    VStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                        Text("No windows")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.40))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Windows scaled into the miniature display workspace (cropped below menu bar)
                ForEach(tile.windows.reversed()) { win in
                    let rawX = (win.bounds.minX - workspaceQuartzRect.minX) * scaleX
                    let rawY = (win.bounds.minY - workspaceQuartzRect.minY) * scaleY
                    let rawW = win.bounds.width * scaleX
                    let rawH = win.bounds.height * scaleY

                    let w = max(18, min(canvasWidth, rawW))
                    let h = max(14, min(canvasHeight, rawH))
                    let x = max(0, min(canvasWidth - w, rawX))
                    let y = max(0, min(canvasHeight - h, rawY))

                    Image(nsImage: PreviewHiddenStyle.image(win.image, hidden: win.isHidden))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: w, height: h)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        // Greyed like every preview's hidden window (the
                        // image above); at this scale the "Hidden" tag
                        // wouldn't fit, so no badge.
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)
                        .offset(x: x, y: y)
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .clipShape(RoundedRectangle(cornerRadius: TilingSpacePreviewLayout.innerRadius, style: .continuous))
    }
}

@available(macOS 14.0, *)
struct DeskspaceCard: View {
    let tile: SpaceTile
    @ObservedObject var model: TilingSpacePreviewModel

    private var isCurrent: Bool {
        tile.number == model.currentNumber
    }

    private var isEmphasized: Bool {
        if let drop = model.dropTarget {
            return drop == tile.number
        }
        return model.highlighted == tile.number
    }

    private var isDropTarget: Bool {
        model.dropTarget == tile.number
    }

    private var isDeleteHeld: Bool {
        model.deleteHold == tile.number
    }

    private var isCarried: Bool {
        model.carried == tile.number
    }

    var body: some View {
        let layout = TilingSpacePreviewLayout.self
        let cardW = model.cardWidth

        VStack(alignment: .center, spacing: 0) {
            // Header / Identity row
            headerView(cardW: cardW)
                .frame(width: cardW, height: layout.headerHeight)

            Spacer().frame(height: layout.headerGap)

            // Deskspace Thumbnail Canvas (Framed in NotchWindowCard style)
            ZStack(alignment: .topTrailing) {
                DeskspaceCanvasView(
                    tile: tile,
                    screenBounds: model.screenBounds,
                    menuBarHeight: model.menuBarHeight,
                    canvasWidth: model.canvasWidth,
                    canvasHeight: model.thumbHeight,
                    wallpaper: model.wallpaper,
                    showsEmptyState: !isDeleteHeld
                )
                .overlay {
                    if isDeleteHeld {
                        DeleteHoldOverlay(progress: model.deleteProgress, windowCount: tile.windows.count)
                            .transition(.opacity)
                    }
                }
                .padding(layout.cardFrame)
                .background(
                    RoundedRectangle(cornerRadius: layout.outerRadius, style: .continuous)
                        .fill(Color.white.opacity(isEmphasized ? 0.12 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: layout.outerRadius, style: .continuous)
                        .strokeBorder(
                            isDeleteHeld ? DeleteHoldOverlay.red
                                : (isDropTarget ? Color.accentColor : (isEmphasized ? Color.accentColor : (isCurrent ? Color.white.opacity(0.24) : Color.white.opacity(0.12)))),
                            lineWidth: (isDeleteHeld || isDropTarget || isEmphasized) ? 2 : 1
                        )
                )

                // Red close button overlay on hover (top trailing, unified traffic-light style)
                if isEmphasized && !model.isGestureControlled && !model.isReordering && model.tiles.count > 1 {
                    PreviewCloseButton(
                        action: {
                            model.onDeleteDesktop(tile.number)
                        },
                        helpText: "Close \(tile.name)",
                        accessibilityText: "Close \(tile.name)"
                    )
                    .padding(6)
                }
            }
            .frame(width: cardW, height: model.thumbnailHeight)
            .shadow(
                color: .black.opacity(isCarried ? 0.5 : (isEmphasized ? 0.35 : 0.0)),
                radius: isCarried ? 20 : (isEmphasized ? 12 : 0),
                y: isCarried ? 12 : (isEmphasized ? 5 : 0)
            )
            // Grows only downward, into the gap above the app icons: growing
            // up (or lifting) ran the thumbnail over the "Desktop N" header.
            .scaleEffect((isEmphasized && !isCarried) ? 1.04 : 1.0, anchor: .top)
            // Held for deletion, the thumbnail sinks with the fingers pulling
            // it down.
            .offset(y: isDeleteHeld ? 4 + 6 * model.deleteProgress : 0)

            // App icons row under thumbnail (replaces app name text, no stacking)
            Spacer().frame(height: layout.bottomGap)

            HStack(spacing: 6) {
                if tile.loaded {
                    if !tile.uniqueApps.isEmpty {
                        ForEach(tile.uniqueApps) { app in
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: layout.appIconSize, height: layout.appIconSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                            }
                        }
                    } else {
                        // Empty space: muted system icon
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: cardW, height: layout.bottomHeight, alignment: .center)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: isEmphasized)
        .overlay(
            CardInteractionCatcher(
                onClick: {
                    guard !model.isReordering else { return }
                    model.onSelectDesktop(tile.number)
                },
                onBeginDrag: { startMouse, _ in
                    guard !tile.isFullscreen && model.tiles.count > 1 && !model.isGestureControlled else { return }
                    model.beginDeskspaceDrag(tile: tile, startMouse: startMouse)
                },
                onDragChanged: { mouse in
                    model.updateDeskspaceDrag(currentMouse: mouse)
                },
                onEndDrag: { mouse in
                    model.endDeskspaceDrag(currentMouse: mouse)
                },
                onCancelDrag: {
                    model.cancelDeskspaceDrag()
                },
                isHitExcluded: { point, bounds in
                    guard isEmphasized && !model.isGestureControlled && !model.isReordering && model.tiles.count > 1 else { return false }
                    let topEdge = bounds.height - (layout.headerHeight + layout.headerGap)
                    return point.x > bounds.width - 32 && point.y <= topEdge && point.y >= topEdge - 32
                }
            )
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: GroupFramesKey.self,
                    value: [tile.number: geometry.frame(in: .named(TilingSpacePreviewLayout.coordinateSpace))]
                )
            }
        )
        .onHover { inside in
            guard !model.isGestureControlled && !model.isReordering else { return }
            if inside {
                model.highlighted = tile.number
            } else if model.highlighted == tile.number {
                model.highlighted = nil
            }
        }
    }

    @ViewBuilder private func headerView(cardW: CGFloat) -> some View {
        let layout = TilingSpacePreviewLayout.self
        HStack(spacing: 5) {
            Image(systemName: tile.isFullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isEmphasized ? .primary : .secondary)

            Text(tile.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEmphasized ? .primary : .secondary)
                .lineLimit(1)

            if isCurrent {
                Text("Current")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            Spacer(minLength: 0)
        }
        .frame(width: cardW, height: layout.headerHeight, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

@available(macOS 14.0, *)
struct TilingSpacePreviewView: View {
    @ObservedObject var model: TilingSpacePreviewModel

    private static let scroll = Animation.easeInOut(duration: 0.24)

    var body: some View {
        let layout = TilingSpacePreviewLayout.self

        Group {
            if model.rowWidth > model.viewportWidth {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        cardsStack
                            .padding(.horizontal, layout.panelPaddingHorizontal)
                            .padding(.vertical, layout.panelPaddingVertical)
                    }
                    .frame(width: model.viewportWidth)
                    .onAppear {
                        if let n = model.highlighted { proxy.scrollTo(n, anchor: .center) }
                    }
                    .onChange(of: model.highlighted) { _, n in
                        guard let n else { return }
                        withAnimation(Self.scroll) { proxy.scrollTo(n, anchor: .center) }
                    }
                }
            } else {
                cardsStack
                    .padding(.horizontal, layout.panelPaddingHorizontal)
                    .padding(.vertical, layout.panelPaddingVertical)
            }
        }
        .opacity(model.contentOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: layout.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout.panelRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: layout.panelRadius, style: .continuous))
        .coordinateSpace(name: layout.coordinateSpace)
        .onPreferenceChange(GroupFramesKey.self) { model.groupFrames = $0 }
        .animation(.easeOut(duration: 0.16), value: model.highlighted)
        .animation(.easeOut(duration: 0.14), value: model.dropTarget)
    }

    @ViewBuilder private var cardsStack: some View {
        HStack(alignment: .top, spacing: TilingSpacePreviewLayout.cardSpacing) {
            ForEach(Array(model.tiles.enumerated()), id: \.element.spaceID) { index, tile in
                let isCarried = model.carried == tile.number
                DeskspaceCard(tile: tile, model: model)
                    .id(tile.spaceID)
                    // Picked up to reorder, card elevates with subtle scale and shadow,
                    // remaining vertically aligned without clipping against panel borders.
                    .scaleEffect(isCarried ? 1.02 : 1)
                    .offset(
                        x: isCarried ? model.carriedOffset : model.offsetForTile(at: index),
                        y: 0
                    )
                    // A carried card passes over its neighbours, not under.
                    .zIndex(isCarried ? 10 : 0)
                    .animation(isCarried ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: model.reorderTargetIndex)
            }
            if model.showAddButton {
                NewDesktopTile(model: model)
            }
        }
    }
}

/// The countdown on a Desktop being held down to delete: a red wash that
/// deepens and a ring that fills over the hold, so the user can see how much
/// longer to keep the fingers down.
@available(macOS 14.0, *)
struct DeleteHoldOverlay: View {
    let progress: CGFloat
    /// Windows that will be closed with the Desktop; 0 for an empty one.
    var windowCount: Int = 0

    static let red = Color(red: 1, green: 0.30, blue: 0.27)

    var body: some View {
        let layout = TilingSpacePreviewLayout.self
        // Sits on the canvas, inset by `cardFrame` inside the card's outer
        // shape: the radius is derived so the corners stay concentric.
        let shape = RoundedRectangle(cornerRadius: layout.outerRadius - layout.cardFrame, style: .continuous)

        ZStack {
            shape.fill(Self.red.opacity(0.16 + 0.34 * progress))
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "trash.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Text(windowCount == 0 ? "Hold to delete"
                     : "Hold to close \(windowCount) window\(windowCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// Adds a Desktop to this display, after the last one — Mission Control's
/// plus. The same frame as a card's thumbnail, dashed while it's empty.
@available(macOS 14.0, *)
struct NewDesktopTile: View {
    @ObservedObject var model: TilingSpacePreviewModel
    @State private var hovering = false

    /// Hovered, or a carried window card is over it and would land on a new Desktop.
    private var active: Bool {
        hovering || model.isAddingDesktop || model.dropTarget == TilingSpacePreviewLayout.newDesktopKey
    }

    var body: some View {
        let layout = TilingSpacePreviewLayout.self
        let shape = RoundedRectangle(cornerRadius: layout.outerRadius, style: .continuous)
        let hovering = active

        VStack(spacing: 0) {
            Spacer().frame(height: layout.headerHeight + layout.headerGap)
            shape
                .fill(Color.white.opacity(hovering ? 0.12 : 0.05))
                .overlay(
                    shape.strokeBorder(hovering ? Color.accentColor : Color.white.opacity(0.18),
                                       style: StrokeStyle(lineWidth: hovering ? 2 : 1, dash: hovering ? [] : [4, 3]))
                )
                .overlay {
                    if model.isAddingDesktop {
                        ProgressView().controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(hovering ? .primary : .secondary)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .frame(width: layout.addTileWidth, height: model.thumbnailHeight)
                .scaleEffect(hovering ? 1.04 : 1)
                .overlay(CardInteractionCatcher(onClick: model.onAddDesktop, onBeginDrag: { _, _ in }))
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: GroupFramesKey.self,
                            value: [layout.newDesktopKey: geometry.frame(in: .named(layout.coordinateSpace))]
                        )
                    }
                )
                .onHover { self.hovering = $0 }
                .help("Add Desktop")
            Spacer().frame(height: layout.bottomGap + layout.bottomHeight)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: active)
    }
}

// MARK: - Controller

/// Hover previews for the tiling control bar's space indicator.
///
/// Rest on any Desktop's pill and a strip of every Desktop on that display
/// drops down beneath the indicator: a group per Desktop holding its windows
/// as cards, with the pill under the pointer's group highlighted. Sliding
/// along the pills only moves the highlight. Click a group to switch to that
/// Desktop, or a card to switch and focus that window; the cards close,
/// fullscreen and drag exactly as they do in the Dock preview and switcher.
/// While a window card is carried, the pills and the groups are drop targets —
/// the bar controller spring-loads the strip and moves the window on release
/// (see `WindowDropTargetProvider`).
///
/// Motion, hover intent and pointer tracking deliberately match
/// `TilingBarPreviewController`, so moving between an icon and a pill feels
/// like one surface.
@available(macOS 14.0, *)
final class TilingSpacePreviewController {

    /// One hover, as the bar reports it.
    struct Target {
        let displayUUID: String
        let screen: NSScreen
        /// The Desktop whose pill the pointer is on.
        let spaceNumber: Int
        /// That pill's column on screen.
        let pill: CGRect
        /// The whole pill row on screen; the strip centres under it.
        let indicator: CGRect
        /// The bar's frame on screen; the card hangs from its bottom edge.
        let bar: CGRect
        let currentSpaceNumber: Int?
        let switchToDesktop: (Int) -> Void
        let activateWindow: (NotchWindowItem) -> Void
        var onCancel: () -> Void = {}
        var deleteDesktop: ((Int) -> Void)? = nil
        var addDesktop: (() -> Void)? = nil
        var reorderDesktops: (([(from: Int, to: Int)], Int?) -> Void)? = nil

        /// One strip per display: pills on the same bar share it.
        var key: String { displayUUID.lowercased() }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<TilingSpacePreviewView>?
    private let model = TilingSpacePreviewModel()

    private(set) var shown: Target?
    private var pending: Target?

    private var hoverTimer: Timer?
    private var dismissTimer: Timer?
    private var timeline: PreviewPanelTimeline?
    private var monitors: [Any] = []
    private var generation = 0

    private var captureTask: Task<Void, Never>?
    private var captureKey: String?

    /// Same intent and grace as the window card.
    private static let hoverDelay: TimeInterval = 0.18
    private static let dismissGrace: TimeInterval = 0.20

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The card on screen, for drop hit-testing; nil while none is shown.
    var cardFrame: CGRect? {
        guard shown != nil, let panel, panel.isVisible else { return nil }
        return panel.frame
    }
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

    /// The bar's report of which pill the pointer is on, or nil for none. Also
    /// driven by a window drag passing over the indicator.
    func hover(_ target: Target?, morphFrom: NSRect? = nil) {
        guard let target, AppSettings.shared.tilingControlBarPreviews else {
            cancelPending()
            if shown != nil { scheduleDismissCheck() } else { removeMonitors() }
            return
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        installMonitors()

        if let shown {
            guard shown.key != target.key else {
                // Same strip: the highlight follows the pointer along the pills.
                self.shown = target
                model.highlighted = target.spaceNumber
                return
            }
            // Another display's bar: its strip replaces this one straight away.
            present(target)
            return
        }

        if let morphFrom {
            // Morphing directly from another preview on the bar (e.g. Window preview).
            // No hover delay: intent is already established.
            cancelPending()
            generation &+= 1
            present(target, morphFrom: morphFrom)
            return
        }

        if pending?.key == target.key {
            // Still resting on the indicator, just on another pill.
            pending = target
            return
        }
        cancelPending()
        generation &+= 1
        let token = generation
        pending = target
        // Capture during the delay rather than after it, so the strip opens
        // with its windows already in place.
        startCaptures(for: target)

        let timer = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            guard let self, self.generation == token, let pending = self.pending else { return }
            self.hoverTimer = nil
            self.present(pending)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// Highlights a group from outside the strip — a window drag over it,
    /// which the strip's own hover tracking never sees.
    func setDropTarget(_ spaceNumber: Int?, highlighting pointed: Int?) {
        if let pointed, model.highlighted != pointed { model.highlighted = pointed }
        guard model.dropTarget != spaceNumber else { return }
        model.dropTarget = spaceNumber
    }

    /// The Desktop group under a point on screen inside the strip, or the
    /// nearest visible one — so a drop in a gutter still lands somewhere
    /// sensible.
    func spaceNumber(atScreenPoint point: NSPoint) -> Int? {
        guard let frame = cardFrame, frame.contains(point), !model.groupFrames.isEmpty else { return nil }
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        let desktops = model.groupFrames.filter { $0.key != TilingSpacePreviewLayout.newDesktopKey }
        if let hit = desktops.first(where: { $0.value.contains(local) }) { return hit.key }
        return desktops
            .filter { $0.value.maxX > 0 && $0.value.minX < frame.width }
            .min { distance(local.x, $0.value) < distance(local.x, $1.value) }?
            .key
    }

    /// Whether a screen point is on the strip's new-Desktop plus tile.
    /// The plus tile's frame on screen, while the strip shows one.
    var newDesktopScreenRect: CGRect? {
        guard model.showAddButton, let frame = cardFrame,
              let tile = model.groupFrames[TilingSpacePreviewLayout.newDesktopKey] else { return nil }
        return CGRect(x: frame.minX + tile.minX, y: frame.maxY - tile.maxY, width: tile.width, height: tile.height)
    }

    /// A window was dropped on the plus tile: it spins while the Desktop is
    /// added, until `refreshDesktops` brings the new one in.
    func setAddingDesktop(_ adding: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { model.isAddingDesktop = adding }
    }

    /// Rebuilds the strip from the display's current Desktops — animated, so a
    /// newly added one slides in where the plus tile was.
    func refreshDesktops() {
        model.isAddingDesktop = false
        guard let shown else { return }
        for tile in model.tiles { TilingSpacePreviewCache.captures.removeValue(forKey: tile.spaceID) }
        captureKey = nil
        present(shown)
    }

    func isOverNewDesktop(atScreenPoint point: NSPoint) -> Bool {
        guard model.showAddButton, let frame = cardFrame, frame.contains(point),
              let tile = model.groupFrames[TilingSpacePreviewLayout.newDesktopKey] else { return false }
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        // A little slack around the narrow tile, so the card needn't be dead on it.
        return tile.insetBy(dx: -8, dy: -8).contains(local)
    }

    private func distance(_ x: CGFloat, _ rect: CGRect) -> CGFloat {
        x < rect.minX ? rect.minX - x : (x > rect.maxX ? x - rect.maxX : 0)
    }

    /// Takes every Desktop again — after a window was dropped onto one, so the
    /// strip shows it leave one group and arrive in another.
    func reload() {
        guard let shown else { return }
        for tile in model.tiles { TilingSpacePreviewCache.captures.removeValue(forKey: tile.spaceID) }
        captureKey = nil
        startCaptures(for: shown)
    }

    func dismiss(animated: Bool = true) {
        cancelPending()
        dismissTimer?.invalidate()
        dismissTimer = nil
        captureTask?.cancel()
        captureTask = nil
        captureKey = nil
        removeMonitors()
        generation &+= 1
        let token = generation

        guard shown != nil, let panel, panel.isVisible else {
            shown = nil
            return
        }
        shown = nil
        model.dropTarget = nil
        model.isReordering = false
        model.carried = nil
        model.carriedOffset = 0
        model.reorderInitialIndex = nil
        model.reorderTargetIndex = nil
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

    // MARK: Opening

    private func cancelPending() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let pending {
            pending.onCancel()
            if captureKey == pending.key {
                captureTask?.cancel()
                captureTask = nil
                captureKey = nil
            }
        }
        pending = nil
    }

    private func present(_ target: Target, morphFrom: NSRect? = nil) {
        let spaces = WindowPreviewCapture.managedSpaces(for: target.screen)
        guard !spaces.isEmpty else {
            cancelPending()
            return
        }
        buildPanelIfNeeded()
        guard let panel else { return }
        let wasShown = (shown != nil && panel.isVisible) || morphFrom != nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        pending = nil
        shown = target

        model.isReordering = false
        model.carried = nil
        model.carriedOffset = 0
        model.reorderInitialIndex = nil
        model.reorderTargetIndex = nil

        model.onSelectDesktop = { [weak self] number in
            self?.dismiss()
            target.switchToDesktop(number)
        }
        model.onDeleteDesktop = { [weak self] number in
            self?.dismiss()
            target.deleteDesktop?(number)
        }
        model.onAddDesktop = { [weak self] in
            self?.dismiss()
            target.addDesktop?()
        }
        model.onReorderDesktops = { [weak self] moves, show in
            target.reorderDesktops?(moves, show)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.dismiss()
            }
        }
        model.onSelectWindow = { [weak self] item in
            self?.dismiss()
            target.activateWindow(item)
        }
        model.onClose = { [weak self] item in
            self?.remove(item)
            Task { await WindowPreviewCapture.closeWindow(pid: item.pid, windowID: item.id) }
        }
        model.onFullscreen = { [weak self] item in
            self?.dismiss()
            Task {
                await WindowPreviewCapture.toggleFullscreen(pid: item.pid, windowID: item.id, bounds: item.bounds)
            }
        }
        model.onCardDropped = { [weak self] in
            // Let go over the strip itself, the drop was onto one of its
            // Desktops: stay open to show the window arrive. Anywhere else
            // took the window to that desktop, and the strip goes with it.
            guard let self, self.cardFrame?.contains(NSEvent.mouseLocation) != true else { return }
            self.dismiss()
        }
        model.panelFrame = { [weak self] in self?.panel?.frame ?? .zero }

        let screen = target.screen
        let layout = TilingBarPreviewLayout.self
        let strip = TilingSpacePreviewLayout.self
        let menuBarHeight = max(24, max(target.bar.height, screen.frame.maxY - screen.visibleFrame.maxY))
        let usableHeight = max(100, screen.frame.height - menuBarHeight)
        let aspect = usableHeight > 0 ? screen.frame.width / usableHeight : 1.6
        let maxThumb = max(70, (usableHeight - target.bar.height) * strip.maxScreenShare)
        let thumbHeight = min(AppSettings.shared.dockPreviewThumbHeight * strip.thumbScale, maxThumb).rounded()
        let tiles = spaces.enumerated().map { index, space -> SpaceTile in
            let cached = TilingSpacePreviewCache.cached(for: space.id)
            return SpaceTile(number: index + 1, spaceID: space.id, isFullscreen: space.isFullscreen,
                             windows: cached ?? [], loaded: cached != nil)
        }

        WallpaperEngine.shared.previewWallpaper(for: target.screen) { [weak self] img in
            self?.model.wallpaper = img
        }

        let apply = {
            self.model.tiles = tiles
            self.model.currentNumber = target.currentSpaceNumber
            self.model.highlighted = target.spaceNumber
            self.model.dropTarget = nil
            self.model.thumbHeight = thumbHeight
            self.model.displayAspect = aspect
            self.model.screenBounds = screen.frame
            self.model.menuBarHeight = menuBarHeight
            self.model.viewportWidth = screen.frame.width - layout.screenInset * 2
            if morphFrom == nil { self.model.contentOpacity = 1 }
        }
        if wasShown && morphFrom == nil {
            withAnimation(.easeOut(duration: 0.18)) { apply() }
        } else {
            apply()
        }
        startCaptures(for: target)

        let frame = computeFrame(target: target)
        if let morphFrom {
            animateMorph(from: morphFrom, to: frame, duration: 0.28)
        } else if wasShown {
            animateFrame(to: frame, duration: 0.24)
        } else {
            dropIn(to: frame)
        }
    }

    /// Captures every Desktop on the target's display that has no fresh
    /// capture, the pointed-at one first and then outward from it, so the
    /// groups nearest the pointer fill in first. One Desktop at a time: each
    /// capture already fans out across that Desktop's windows.
    private func startCaptures(for target: Target) {
        let key = target.key
        guard captureKey != key else { return }
        captureTask?.cancel()
        captureKey = key

        captureTask = Task { @MainActor in
            let spaces = WindowPreviewCapture.managedSpaces(for: target.screen)
            let order = spaces.indices.sorted {
                abs($0 + 1 - target.spaceNumber) < abs($1 + 1 - target.spaceNumber)
            }
            for index in order {
                let space = spaces[index]
                if let cached = TilingSpacePreviewCache.cached(for: space.id) {
                    fill(space.id, with: cached)
                    continue
                }
                let windows = await WindowPreviewCapture.captureScreenWindows(
                    screen: target.screen, onSpace: space.id,
                    maxWindows: TilingSpacePreviewLayout.maxWindows
                )
                guard !Task.isCancelled, captureKey == key else { return }
                remember(windows, for: space.id)
                fill(space.id, with: windows)
            }
            guard captureKey == key else { return }
            captureKey = nil
            captureTask = nil
        }
    }

    /// Puts a capture into its group, if the strip on screen has that Desktop,
    /// and resizes the panel to the row it now makes.
    private func fill(_ spaceID: UInt64, with windows: [NotchWindowItem]) {
        guard let index = model.tiles.firstIndex(where: { $0.spaceID == spaceID }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            model.tiles[index].windows = windows
            model.tiles[index].loaded = true
        }
        resizeToContent()
    }

    /// A closed window leaves its group at once, rather than on the next capture.
    private func remove(_ item: NotchWindowItem) {
        guard let index = model.tiles.firstIndex(where: { $0.windows.contains { $0.id == item.id } }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            model.tiles[index].windows.removeAll { $0.id == item.id }
        }
        remember(model.tiles[index].windows, for: model.tiles[index].spaceID)
        resizeToContent()
    }

    private func remember(_ windows: [NotchWindowItem], for spaceID: UInt64) {
        TilingSpacePreviewCache.remember(windows, for: spaceID)
    }

    // MARK: Geometry

    private func resizeToContent() {
        guard let shown, let panel, panel.isVisible else { return }
        guard timeline == nil else { return }
        let frame = computeFrame(target: shown)
        guard abs(frame.width - panel.frame.width) > 1 || abs(frame.height - panel.frame.height) > 1
                || abs(frame.minX - panel.frame.minX) > 1 else { return }
        animateFrame(to: frame, duration: 0.2)
    }

    /// Where the strip sits: centred under the pill row, hanging `gapBelowBar`
    /// below the bar, kept clear of the screen's sides. Sized from the layout
    /// alone — every part has a fixed size — so nothing waits on SwiftUI to
    /// measure it.
    private func computeFrame(target: Target) -> NSRect {
        let layout = TilingBarPreviewLayout.self
        let strip = TilingSpacePreviewLayout.self
        let size = NSSize(width: ceil(min(model.rowWidth, model.viewportWidth)),
                          height: ceil(model.cardHeight + strip.panelPaddingVertical * 2))
        let screen = target.screen.frame
        let x = min(max(target.indicator.midX - size.width / 2, screen.minX + layout.screenInset),
                    screen.maxX - size.width - layout.screenInset)
        let y = target.bar.minY - layout.gapBelowBar - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Motion

    /// Slides out from under the bar and settles with a slight give, as if it
    /// had dropped from the indicator.
    private func dropIn(to frame: NSRect) {
        guard let panel else { return }
        timeline?.cancel()
        model.contentOpacity = 1
        // If the frame's right edge reaches under/near the physical notch cutout,
        // do not tuck vertically behind the bar into the physical notch cutout.
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

    /// The strip, the pill row, and the gap joining them, so moving down from
    /// any pill never crosses a gap that counts as leaving. The bridge stops at
    /// the bar's bottom edge: the strip is wide, and the app icons above it
    /// belong to the window card, not to this one.
    private func pointerIsInside() -> Bool {
        guard let shown, let panel, panel.isVisible else { return false }
        let point = NSEvent.mouseLocation
        let anchor = shown.indicator.union(shown.pill)
        let card = panel.frame.insetBy(dx: -6, dy: -6)
        let bridgeMinY = min(card.maxY - 4, shown.bar.minY - 2)
        let bridgeMaxY = max(card.maxY + 4, shown.bar.minY + 2)
        let bridgeMinX = min(card.minX, anchor.minX) - 4
        let bridgeMaxX = max(card.maxX, anchor.maxX) + 4
        let bridge = CGRect(x: bridgeMinX, y: bridgeMinY,
                            width: bridgeMaxX - bridgeMinX, height: bridgeMaxY - bridgeMinY)
        return card.contains(point) || bridge.contains(point)
            || anchor.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func scheduleDismissCheck() {
        guard dismissTimer == nil else { return }
        let timer = Timer(timeInterval: Self.dismissGrace, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dismissTimer = nil
            // A card lifted off the strip is still this strip's until dropped.
            guard !self.model.isReordering && !WindowPreviewDragController.shared.isDragging else { return }
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
        if shown != nil {
            if pointerIsInside() || model.isReordering {
                dismissTimer?.invalidate()
                dismissTimer = nil
            } else {
                scheduleDismissCheck()
            }
        } else if let pending,
                  !pending.indicator.union(pending.pill).insetBy(dx: -8, dy: -6).contains(NSEvent.mouseLocation) {
            // Left the indicator before intent was established.
            cancelPending()
            removeMonitors()
        }
    }

    private func pointerClicked() {
        guard shown != nil else {
            cancelPending()
            return
        }
        guard !model.isReordering else { return }
        // Clicks on the strip are the strip's own; anything else closes it.
        guard let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }

    // MARK: Panel

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: TilingSpacePreviewView(model: model))
        // Sized by this controller only, or the hosting view pushes its own
        // size onto the window mid-animation.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = view
        p.isFloatingPanel = true
        // Same level as the window card: beneath the bar and its backdrop, so
        // the drop-in slides out from behind the bar.
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
