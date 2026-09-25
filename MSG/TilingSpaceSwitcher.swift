import AppKit
import SwiftUI

@_silgen_name("CGSMainConnectionID")
private func SpaceSwitcherCGSMainConnectionID() -> UInt32

@_silgen_name("CGSSetConnectionProperty")
private func SpaceSwitcherCGSSetConnectionProperty(_ cid: UInt32, _ targetCID: UInt32,
                                                   _ key: CFString, _ value: CFTypeRef) -> Int32

/// Shows the deskspace preview HUD in the center of the display during a
/// horizontal multi-finger trackpad swipe, allowing the user to scrub between
/// deskspaces and switch on gesture release.
@available(macOS 14.0, *)
final class TilingSpaceSwitcher {

    struct Layout {
        static let stepTravel: CGFloat = 0.055
        static let fadeDuration: CFTimeInterval = 0.15
        static let thumbHeight: CGFloat = 140
        /// Downward travel (share of trackpad height) on a Desktop that
        /// starts the hold-to-delete countdown.
        static let deleteArmTravel: CGFloat = 0.2
        /// Coming back up past this cancels it — below the arm travel, so a
        /// finger hovering at the threshold doesn't flicker it on and off.
        static let deleteDisarmTravel: CGFloat = 0.13
        /// How long the fingers must stay down to delete.
        static let deleteHoldDuration: TimeInterval = 1.5
        /// The highlight must rest on the Desktop this long before a pull
        /// can arm, so a scrub that sags on its way past never does.
        static let deleteSettleTime: CFTimeInterval = 0.35
        /// Sideways travel allowed per unit of the pull down since settling:
        /// the pull has to be clearly downward, not a diagonal scrub.
        static let deleteMaxDrift: CGFloat = 0.5
        /// Upward travel that picks the highlighted Desktop up to reorder.
        /// Shorter than the delete pull: nothing is lost if it's a mistake —
        /// dropping it back where it was does nothing.
        static let pickUpTravel: CGFloat = 0.12
        /// Pulling back down this far from the highest point reached while
        /// carrying places the Desktop where it is and resumes scrubbing.
        static let carryPlaceTravel: CGFloat = 0.1
    }

    private struct Session {
        let screen: NSScreen
        let displayUUID: String
        let spaces: [(id: UInt64, isFullscreen: Bool)]
        let initialIndex: Int
        var selected: Int
        var lastOffset: CGFloat
        let startTime: TimeInterval
        /// Highest vertical position since the highlight last moved; a pull
        /// down is measured from here.
        var baselineRise: CGFloat = 0
        /// When and where (sideways) the highlight last landed on `selected`.
        var settledAt: CFTimeInterval = 0
        var settledOffset: CGFloat = 0
        /// Lowest vertical position since the highlight last moved; a push
        /// up is measured from here.
        var baselineLow: CGFloat = 0
        /// The hold-to-delete countdown is running on `selected`.
        var deleteArmed = false
        /// A Desktop picked up to reorder: its original index, the sideways
        /// offset it was picked up at, where it would land now, and the
        /// indices it may move within (fullscreen Spaces bound it).
        var carry: (from: Int, pickOffset: CGFloat, to: Int, range: ClosedRange<Int>)?
        /// Highest vertical position while carrying, for the abort pull.
        var carryPeakRise: CGFloat = 0
        /// Where scrubbing is measured from: the sideways offset and Desktop
        /// index it started at. The gesture start at first; re-anchored when a
        /// reorder is abandoned, so scrubbing resumes from the put-back
        /// Desktop instead of jumping by the distance the carry travelled.
        var scrubOrigin: CGFloat = 0
        var scrubBaseIndex: Int = 0
        /// Placements made this swipe (0-based, in order). Only shown in the
        /// HUD until the swipe ends; applying them live swapped the contents
        /// of the Desktop in view before the user had moved to it.
        var pendingMoves: [(from: Int, to: Int)] = []
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<TilingSpacePreviewView>?
    private let model = TilingSpacePreviewModel()
    private var session: Session?
    private var captureTask: Task<Void, Never>?
    private var isPresented: Bool = false
    private var isCursorHidden = false
    private var deleteHoldWork: DispatchWorkItem?

    var onSwitchSpace: ((String, Int) -> Void)?
    /// (displayUUID, 1-based Desktop number, its windows to close first) —
    /// a completed hold-to-delete.
    var onDeleteSpace: ((String, Int, [NotchWindowItem]) -> Void)?
    /// (displayUUID, moves, show) — the Desktops reordered in one swipe, as
    /// 1-based (from, to) pairs applied in order, and the position to be on
    /// afterwards (nil to stay put).
    var onReorderSpaces: ((String, [(from: Int, to: Int)], Int?) -> Void)?
    var isMissionControlActive: (() -> Bool)?

    init() {
        model.showAddButton = false
        model.isGestureControlled = true
    }

    deinit {
        restoreCursor()
    }

    /// The pointer is hidden while the HUD is up: the fingers are scrubbing,
    /// not pointing. Same pairing as `TilingTabSwitcher`.
    private func hideCursor() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        // MSG is never frontmost here, and WindowServer ignores cursor hiding
        // from a background app unless its connection opts in.
        let cid = SpaceSwitcherCGSMainConnectionID()
        _ = SpaceSwitcherCGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        CGDisplayHideCursor(CGMainDisplayID())
        NSCursor.hide()
    }

    private func restoreCursor() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
    }

    // MARK: - Gesture Lifecycle

    func begin(screen: NSScreen, displayUUID: String, spaces: [(id: UInt64, isFullscreen: Bool)], initialIndex: Int) {
        guard spaces.count > 1 else { return }
        guard initialIndex >= 0 && initialIndex < spaces.count else { return }
        guard isMissionControlActive?() != true else { return }

        captureTask?.cancel()
        captureTask = nil

        session = Session(
            screen: screen,
            displayUUID: displayUUID,
            spaces: spaces,
            initialIndex: initialIndex,
            selected: initialIndex,
            lastOffset: 0,
            startTime: CACurrentMediaTime(),
            scrubBaseIndex: initialIndex
        )

        present(screen: screen, spaces: spaces, initialIndex: initialIndex)
        hideCursor()
    }

    func change(_ offset: CGFloat, rise: CGFloat = 0) {
        guard var session else { return }
        session.lastOffset = offset

        if var carry = session.carry {
            session.carryPeakRise = max(session.carryPeakRise, rise)
            if session.carryPeakRise - rise >= Layout.carryPlaceTravel {
                // Pulled back down: place the Desktop where it is now and carry
                // on scrubbing from it. Every baseline restarts here, so it
                // takes a fresh rest and push to pick up (or pull to delete).
                session.carry = nil
                session.selected = carry.to
                session.scrubOrigin = offset
                session.scrubBaseIndex = carry.to
                session.baselineRise = rise
                session.baselineLow = rise
                session.settledAt = CACurrentMediaTime()
                session.settledOffset = offset
                self.session = session
                if carry.to != carry.from {
                    session.pendingMoves.append((carry.from, carry.to))
                    self.session = session
                    realignTiles(to: session)
                    model.currentNumber = model.currentNumber.map { reordered($0 - 1, from: carry.from, to: carry.to) + 1 }
                }
                HapticFeedback.perform(.generic, actuationType: 1)
                withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                    model.carried = nil
                    model.highlighted = carry.to + 1
                }
                return
            }
            self.session = session
            // Carrying: sideways travel since the pick-up slides the Desktop
            // through the row; pulling down abandons it (above).
            let delta = Int(((offset - carry.pickOffset) / Layout.stepTravel).rounded(.towardZero))
            let to = min(max(carry.from + delta, carry.range.lowerBound), carry.range.upperBound)
            guard to != carry.to else { return }
            carry.to = to
            session.carry = carry
            self.session = session
            moveCarried(from: carry.from, to: to, in: session)
            HapticFeedback.tick()
            return
        }

        if session.deleteArmed {
            // Counting down: sideways drift is ignored so the doomed Desktop
            // can't change under the fingers. Only lifting back up cancels.
            if session.baselineRise - rise < Layout.deleteDisarmTravel {
                session.deleteArmed = false
                self.session = session
                disarmDelete()
            }
            return
        }

        // Scrubbing: fingers right (offset > 0) moves the highlight to the
        // next space, fingers left to the previous one.
        let delta = Int(((offset - session.scrubOrigin) / Layout.stepTravel).rounded(.towardZero))
        let targetIndex = min(max(session.scrubBaseIndex + delta, 0), session.spaces.count - 1)

        let moved = targetIndex != session.selected
        session.selected = targetIndex
        session.baselineRise = moved ? rise : max(session.baselineRise, rise)
        session.baselineLow = moved ? rise : min(session.baselineLow, rise)
        if moved || session.settledAt == 0 {
            session.settledAt = CACurrentMediaTime()
            session.settledOffset = offset
        }

        let settled = !moved && CACurrentMediaTime() - session.settledAt >= Layout.deleteSettleTime
        let drift = abs(offset - session.settledOffset)

        let pull = session.baselineRise - rise
        if settled, pull >= Layout.deleteArmTravel, drift <= pull * Layout.deleteMaxDrift,
           canDelete(index: targetIndex, in: session) {
            session.deleteArmed = true
            self.session = session
            armDelete(session)
            return
        }

        let push = rise - session.baselineLow
        if settled, push >= Layout.pickUpTravel, drift <= push * Layout.deleteMaxDrift,
           let range = reorderRange(around: targetIndex, in: session) {
            session.carry = (from: targetIndex, pickOffset: offset, to: targetIndex, range: range)
            session.carryPeakRise = rise
            self.session = session
            HapticFeedback.perform(.generic, actuationType: 1)
            withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                model.carried = targetIndex + 1
            }
            return
        }
        self.session = session

        guard moved else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
            model.highlighted = targetIndex + 1
        }
        HapticFeedback.tick()
    }

    func end() {
        guard let session else { return }
        self.session = nil
        captureTask?.cancel()
        captureTask = nil

        restoreCursor()

        // Lifted mid-countdown: the pull down meant "delete", not "go there",
        // so letting go early cancels both. Placements still apply, and the
        // display follows the Desktop it was showing.
        if session.deleteArmed {
            disarmDelete()
            dismiss()
            commit(session.pendingMoves, show: followedIndex(session.pendingMoves, in: session), in: session)
            return
        }
        // Lifted while carrying: that's a placement too. The display follows
        // the Desktop it was showing — onto its new position if it was moved.
        if let carry = session.carry {
            dismiss()
            model.carried = nil
            let moves = session.pendingMoves + (carry.to != carry.from ? [(carry.from, carry.to)] : [])
            commit(moves, show: followedIndex(moves, in: session), in: session)
            return
        }
        dismiss()

        if !session.pendingMoves.isEmpty {
            commit(session.pendingMoves, show: session.selected, in: session)
        } else if session.selected != session.initialIndex, isMissionControlActive?() != true {
            onSwitchSpace?(session.displayUUID, session.selected + 1)
        }
    }

    /// Hands the swipe's placements to the controller, which switches to
    /// `show` first and then moves the windows.
    private func commit(_ moves: [(from: Int, to: Int)], show: Int?, in session: Session) {
        guard !moves.isEmpty, isMissionControlActive?() != true else {
            if let show, show != session.initialIndex, isMissionControlActive?() != true {
                onSwitchSpace?(session.displayUUID, show + 1)
            }
            return
        }
        onReorderSpaces?(session.displayUUID, moves.map { ($0.from + 1, $0.to + 1) }, show.map { $0 + 1 })
    }

    /// Where the Desktop the display was showing ends up after `moves`.
    private func followedIndex(_ moves: [(from: Int, to: Int)], in session: Session) -> Int {
        moves.reduce(session.initialIndex) { reordered($0, from: $1.from, to: $1.to) }
    }

    func cancel() {
        deleteHoldWork?.cancel()
        deleteHoldWork = nil
        model.deleteHold = nil
        model.carried = nil
        captureTask?.cancel()
        captureTask = nil
        session = nil
        restoreCursor()
        panel?.orderOut(nil)
        isPresented = false
    }

    // MARK: - Hold to delete

    /// Any Desktop whose capture has landed — its windows, hidden and
    /// minimized ones included, are what gets closed — but never a
    /// fullscreen app's Space or the display's last one.
    private func canDelete(index: Int, in session: Session) -> Bool {
        guard onDeleteSpace != nil, session.spaces.count > 1,
              session.spaces.indices.contains(index), !session.spaces[index].isFullscreen,
              let tile = tile(for: session.spaces[index].id) else { return false }
        return tile.loaded
    }

    private func tile(for spaceID: UInt64) -> SpaceTile? {
        model.tiles.first { $0.spaceID == spaceID }
    }

    private func armDelete(_ session: Session) {
        let number = session.selected + 1
        HapticFeedback.tick()
        model.deleteHold = number
        model.deleteProgress = 0
        // The ring fills over exactly the hold, so a full ring is the delete.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.deleteHold == number else { return }
            withAnimation(.linear(duration: Layout.deleteHoldDuration)) {
                self.model.deleteProgress = 1
            }
        }
        deleteHoldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitDelete() }
        deleteHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.deleteHoldDuration, execute: work)
    }

    private func disarmDelete() {
        deleteHoldWork?.cancel()
        deleteHoldWork = nil
        withAnimation(.easeOut(duration: 0.15)) {
            model.deleteProgress = 0
            model.deleteHold = nil
        }
    }

    private func commitDelete() {
        deleteHoldWork = nil
        guard let session, session.deleteArmed else { return }
        self.session = nil
        captureTask?.cancel()
        captureTask = nil
        HapticFeedback.perform(.levelChange, actuationType: 1)
        restoreCursor()
        dismiss()
        model.deleteHold = nil
        guard isMissionControlActive?() != true else { return }
        // Placements earlier in the swipe land before the delete (the
        // controller queues it behind them); the display stays put.
        if !session.pendingMoves.isEmpty {
            onReorderSpaces?(session.displayUUID, session.pendingMoves.map { ($0.from + 1, $0.to + 1) }, nil)
        }
        let windows = tile(for: session.spaces[session.selected].id)?.windows ?? []
        onDeleteSpace?(session.displayUUID, session.selected + 1, windows)
    }

    // MARK: - Reorder

    /// The indices a Desktop at `index` can move between: the run of regular
    /// Desktops around it. Fullscreen Spaces can't take other windows, so a
    /// reorder — done by moving windows — can't reach or cross one. Nil when
    /// there's nowhere to go.
    private func reorderRange(around index: Int, in session: Session) -> ClosedRange<Int>? {
        guard onReorderSpaces != nil, session.spaces.indices.contains(index),
              !session.spaces[index].isFullscreen,
              tile(for: session.spaces[index].id)?.loaded == true else { return nil }
        var lo = index, hi = index
        while lo > 0, !session.spaces[lo - 1].isFullscreen { lo -= 1 }
        while hi < session.spaces.count - 1, !session.spaces[hi + 1].isFullscreen { hi += 1 }
        return lo < hi ? lo...hi : nil
    }

    /// Where the Desktop at `index` sits after the one at `from` moves to `to`.
    private func reordered(_ index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < to, index > from, index <= to { return index - 1 }
        if to < from, index >= to, index < from { return index + 1 }
        return index
    }

    /// After a placement, renumbers the row by position: tile N is Space N
    /// again, now showing the contents that moved there. Without this, the
    /// tiles keep their old Space ids, and a delete later in the same swipe
    /// would read the windows of whatever used to be at that position.
    private func realignTiles(to session: Session) {
        let tiles = model.tiles.enumerated().map { index, tile in
            SpaceTile(number: index + 1, spaceID: session.spaces[index].id,
                      isFullscreen: session.spaces[index].isFullscreen,
                      windows: tile.windows, loaded: tile.loaded)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.tiles = tiles }
    }

    /// Shows the row as it would be with the carried Desktop at `to`.
    private func moveCarried(from: Int, to: Int, in session: Session) {
        var order = session.spaces.map(\.id)
        let id = order.remove(at: from)
        order.insert(id, at: to)
        let byID = Dictionary(uniqueKeysWithValues: model.tiles.map { ($0.spaceID, $0) })
        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
            model.tiles = order.compactMap { byID[$0] }
        }
    }

    // MARK: - Presentation

    private func present(screen: NSScreen, spaces: [(id: UInt64, isFullscreen: Bool)], initialIndex: Int) {
        buildPanelIfNeeded()
        guard let panel else { return }

        let layout = TilingBarPreviewLayout.self
        let strip = TilingSpacePreviewLayout.self
        let menuBarHeight: CGFloat = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let usableHeight = max(100, screen.frame.height - menuBarHeight)
        let aspect = usableHeight > 0 ? screen.frame.width / usableHeight : 1.6

        let tiles = spaces.enumerated().map { index, space -> SpaceTile in
            let cached = TilingSpacePreviewCache.cached(for: space.id)
            return SpaceTile(
                number: index + 1,
                spaceID: space.id,
                isFullscreen: space.isFullscreen,
                windows: cached ?? [],
                loaded: cached != nil
            )
        }

        WallpaperEngine.shared.previewWallpaper(for: screen) { [weak self] img in
            self?.model.wallpaper = img
        }

        model.tiles = tiles
        model.currentNumber = initialIndex + 1
        model.highlighted = initialIndex + 1
        model.dropTarget = nil
        model.thumbHeight = Layout.thumbHeight
        model.displayAspect = aspect
        model.screenBounds = screen.frame
        model.menuBarHeight = menuBarHeight
        model.viewportWidth = screen.frame.width - layout.screenInset * 2
        model.contentOpacity = 1.0

        let width = ceil(min(model.rowWidth, model.viewportWidth))
        let height = ceil(model.cardHeight + strip.panelPaddingVertical * 2)
        let size = NSSize(width: width, height: height)

        let x = (screen.frame.minX + (screen.frame.width - size.width) / 2).rounded()
        let y = (screen.frame.minY + (screen.frame.height - size.height) / 2).rounded()
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isPresented = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }

        startCaptures(for: screen, spaces: spaces)
    }

    private func dismiss() {
        guard isPresented, let panel, panel.isVisible else {
            panel?.orderOut(nil)
            isPresented = false
            return
        }

        isPresented = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        })
    }

    private func startCaptures(for screen: NSScreen, spaces: [(id: UInt64, isFullscreen: Bool)]) {
        captureTask = Task { [weak self] in
            for space in spaces {
                guard !Task.isCancelled else { return }
                if TilingSpacePreviewCache.cached(for: space.id) == nil {
                    let windows = await WindowPreviewCapture.captureScreenWindows(
                        screen: screen, onSpace: space.id,
                        maxWindows: TilingSpacePreviewLayout.maxWindows
                    )
                    guard !Task.isCancelled else { return }
                    TilingSpacePreviewCache.remember(windows, for: space.id)
                    await MainActor.run { [weak self] in
                        guard let self, self.session != nil else { return }
                        if let i = self.model.tiles.firstIndex(where: { $0.spaceID == space.id }) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                self.model.tiles[i].windows = windows
                                self.model.tiles[i].loaded = true
                            }
                        }
                    }
                }
            }
        }
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: TilingSpacePreviewView(model: model))
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = view
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: 24)
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
