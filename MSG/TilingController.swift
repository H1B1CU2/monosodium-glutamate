import AppKit
import ApplicationServices

private typealias TilingCGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func TilingCGSMainConnectionID() -> TilingCGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func TilingCGSCopyManagedDisplaySpaces(_ cid: TilingCGSConnectionID) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func TilingCGSCopySpacesForWindows(_ cid: TilingCGSConnectionID, _ mask: Int, _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGSManagedDisplayIsAnimating")
private func TilingCGSManagedDisplayIsAnimating(_ cid: TilingCGSConnectionID, _ display: CFString) -> Bool

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
private func TilingSLSCopyWindowsWithOptionsAndTags(
    _ cid: TilingCGSConnectionID, _ owner: UInt32, _ spaces: CFArray,
    _ options: UInt32, _ setTags: UnsafeMutablePointer<UInt64>,
    _ clearTags: UnsafeMutablePointer<UInt64>
) -> CFArray?

@_silgen_name("_AXUIElementGetWindow")
private func TilingAXUIElementGetWindow(_ element: AXUIElement,
                                        _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("MSGPostSpaceJump")
private func MSGPostSpaceJump(_ direction: Int32, _ steps: Int32) -> Int32

private struct TilingSpaceKey: Hashable {
    let displayUUID: String
    let spaceID: Int
}


private struct TilingVisibleSpace {
    let key: TilingSpaceKey
    let number: Int
    let total: Int
    let screen: NSScreen
    let isFullscreen: Bool
}

private struct ManagedTilingWindow {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let icon: NSImage?
    let element: AXUIElement
    let frame: CGRect
    let displayUUID: String
    let spaceIDs: [Int]
    let automaticallyFloating: Bool
}

private struct TilingWorkspaceState {
    var tree: TilingTree?
    var mode: TilingLayoutMode = .masterStack
    /// Windows assigned to the left-hand tab group. `masterID` is the tab
    /// currently presented in that group; the remaining members stay stacked.
    var mainTabIDs: Set<CGWindowID> = []
    /// Distinguishes a new workspace (whose first window starts left) from an
    /// intentionally empty left column after its tabs were merged right.
    var columnsInitialized = false
    var masterID: CGWindowID?
    /// The tab currently presented in the right-hand group.
    var stackID: CGWindowID?
    var masterRatio: CGFloat = 0.50
    var lastFocusedID: CGWindowID?
    var floatingIDs: Set<CGWindowID> = []
    var paused = false
}

struct TilingBarWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String
    let name: String
    let appName: String
    let title: String
    let icon: NSImage?
    let frame: CGRect
    let isFocused: Bool
    let isShownInLayout: Bool
    var status: TilingWindowStatus = .split
    var floatingIsAutomatic = false
    var spaceNumber: Int = 1
    var spaceName: String = ""

    init(windowID: CGWindowID, pid: pid_t, bundleID: String, name: String,
         appName: String = "", title: String = "",
         icon: NSImage?, frame: CGRect, isFocused: Bool,
         isShownInLayout: Bool = false,
         status: TilingWindowStatus = .split,
         floatingIsAutomatic: Bool = false,
         spaceNumber: Int = 1, spaceName: String = "") {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.appName = appName.isEmpty ? name : appName
        self.title = title
        self.icon = icon
        self.frame = frame
        self.isFocused = isFocused
        self.isShownInLayout = isShownInLayout
        self.status = status
        self.floatingIsAutomatic = floatingIsAutomatic
        self.spaceNumber = spaceNumber
        self.spaceName = spaceName
    }

    func withShownInLayout(_ shown: Bool) -> TilingBarWindow {
        TilingBarWindow(
            windowID: windowID, pid: pid, bundleID: bundleID, name: name,
            appName: appName, title: title,
            icon: icon, frame: frame, isFocused: isFocused,
            isShownInLayout: shown, status: status,
            floatingIsAutomatic: floatingIsAutomatic,
            spaceNumber: spaceNumber, spaceName: spaceName
        )
    }
}

enum TilingControlBarScope: String, CaseIterable, Codable {
    case currentSpace = "Current Space"
    case allSpaces = "All Spaces"
}

enum TilingPillScope: String, CaseIterable, Codable {
    case currentSpace = "Current Deskspace"
    case allSpaces = "All Deskspaces"
}

struct TilingBarSnapshot {
    let displayUUID: String
    let spaceNumber: Int
    let spaceCount: Int
    let mode: TilingLayoutMode
    let paused: Bool
    let windows: [TilingBarWindow]
    let focusedStatus: TilingWindowStatus
    var focusedIsFloating: Bool = false
    var scope: TilingControlBarScope = .currentSpace
    var pillScope: TilingPillScope = .currentSpace

    init(displayUUID: String, spaceNumber: Int, spaceCount: Int,
         mode: TilingLayoutMode, paused: Bool, windows: [TilingBarWindow],
         focusedStatus: TilingWindowStatus, focusedIsFloating: Bool = false,
         scope: TilingControlBarScope = .currentSpace,
         pillScope: TilingPillScope = .currentSpace) {
        self.displayUUID = displayUUID
        self.spaceNumber = spaceNumber
        self.spaceCount = spaceCount
        self.mode = mode
        self.paused = paused
        self.windows = windows
        self.focusedStatus = focusedStatus
        self.focusedIsFloating = focusedIsFloating
        self.scope = scope
        self.pillScope = pillScope
    }
}

/// Automatic tiling for the currently visible native Space on every display.
/// Hidden Spaces are deliberately untouched and are reconciled when macOS
/// makes them visible.
final class TilingController {
    static let shared = TilingController(settings: .shared)

    private struct CachedAllBarWindow {
        var window: TilingBarWindow
        let displayUUID: String
        var lastConfirmedAt: TimeInterval
    }

    private struct EmptySpaceCandidate {
        let displayUUID: String
        let displayID: CGDirectDisplayID
        let spaceID: Int
        let spaceIndex: Int
        /// How many Spaces the display had when the candidate was chosen, so
        /// Mission Control's list can be checked against it before removing.
        let spaceCount: Int
    }

    private struct ActiveFrameAnimation {
        let element: AXUIElement
        let displayID: CGDirectDisplayID
        let start: CGRect
        let target: CGRect
        let initialVelocity: TilingFrameVelocity
        let startedAt: TimeInterval
        let duration: TimeInterval
    }

    private static let frameSpringResponse: CGFloat = 22
    private static let frameSpringDuration: TimeInterval = 0.32

    private struct ActiveHandleDragSession {
        let spaceKey: TilingSpaceKey
        let screen: NSScreen
        let work: CGRect
        let gap: CGFloat
        var cachedElements: [CGWindowID: AXUIElement]
        var currentState: TilingWorkspaceState
        var minSizes: [CGWindowID: CGSize] = [:]
    }

    private let menuBar = TilingMenuBar()
    private var mouseMonitor: Any?
    private var resizeStart: (
        id: CGWindowID,
        frame: CGRect,
        key: TilingSpaceKey,
        work: CGRect,
        state: TilingWorkspaceState,
        space: TilingVisibleSpace,
        draggedElement: AXUIElement,
        neighbors: [(id: CGWindowID, element: AXUIElement)]
    )?
    private var resizeWork: DispatchWorkItem?
    private var overlayResizeWork: DispatchWorkItem?
    private var pendingOverlayResize: (divider: TilingDivider, coordinate: CGFloat)?
    private var dropPoint: CGPoint?
    private var gestureHasResized = false
    private var dragStartPoint: CGPoint?
    /// Whether the press landed in the window's title-bar strip. Only then does
    /// pointer travel alone count as moving the window; a drag inside the
    /// content — selecting text, marquee-selecting files — must actually move
    /// the window before a drop tile appears or a drop is committed.
    private var dragStartedInTitleBar = false
    private static let titleBarDragHeight: CGFloat = 52

    /// The drag origin to hand the drop logic: nil unless the press was in the
    /// title bar, so a content drag is judged by window movement only.
    private var windowDragStartPoint: CGPoint? {
        dragStartedInTitleBar ? dragStartPoint : nil
    }
    private var dragStartedOnResizeEdge = false
    private var appliedFrames: [CGWindowID: (target: CGRect, actual: CGRect)] = [:]
    /// What a window turned out to refuse to shrink past, learned from the size
    /// it kept after a write. Apps rarely publish `AXMinSize`, so this is the
    /// only honest source; without it a too-narrow tile leaves the window lying
    /// over its neighbour instead of fitting beside it.
    private var learnedMinimums: [CGWindowID: CGSize] = [:]
    private var frameAnimations: [CGWindowID: ActiveFrameAnimation] = [:]
    private var frameAnimationClocks: [CGDirectDisplayID: TilingDisplayClock] = [:]
    private let framePipeline = TilingFramePipeline()
    private var pendingFrameTargets: [CGWindowID: CGRect] = [:]
    /// One-shot work to run once the pipeline's current writes have settled.
    private var afterFrameWrites: [() -> Void] = []
    private var lastWindowScan: (stamp: TimeInterval, windows: [ManagedTilingWindow])?
    private static let windowScanReuseWindow: TimeInterval = 0.3
    private var allBarWindowsCache: [String: (stamp: TimeInterval, key: String, windows: [TilingBarWindow])] = [:]
    private static let allBarWindowsMaxAge: TimeInterval = 1.0
    private let settings: AppSettings
    private let controlBar = TilingControlBarController()
    private let resizeOverlay = TilingResizeOverlayController()
    private var handleDragSession: ActiveHandleDragSession?
    private var states: [TilingSpaceKey: TilingWorkspaceState] = [:]
    private var shownWindowIDsBySpace: [TilingSpaceKey: Set<CGWindowID>] = [:]
    private var allBarWindowCache: [CGWindowID: CachedAllBarWindow] = [:]
    private var orderedWindowIDsBySpace: [String: [CGWindowID]] = [:]
    private var visibleWindowLastSeenAt: [CGWindowID: TimeInterval] = [:]
    private var emptySpaceSince: [Int: TimeInterval] = [:]
    private var lastEmptySpaceScanAt: TimeInterval = 0
    private var isRemovingEmptySpace = false
    /// Launch-only routing. Once an app has either reused an empty Deskspace or
    /// been moved to a new one, MSG leaves every later manual move alone.
    private var appIsolationWorkByPID: [pid_t: DispatchWorkItem] = [:]
    private var appsBeingIsolated = Set<pid_t>()
    private var programmaticTargetSpaceByDisplay: [String: Int] = [:]
    private var programmaticTargetSetAt: [String: CFTimeInterval] = [:]
    /// Longest a click's destination is trusted over what WindowServer reports:
    /// enough for the keyboard fallback to step across several Desktops, short
    /// enough that a switch which never happens can't pin the indicator.
    private static let programmaticTargetLifetime: CFTimeInterval = 4.0
    private var nativeSpaceSwitchGeneration = 0
    private var observations: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var refreshWork: DispatchWorkItem?
    private var spaceSettlingWork: DispatchWorkItem?
    private var isSettlingSpaceSwitch = false
    /// Windows are being shuffled between Desktops by `reorderSpace`. Polling
    /// pauses meanwhile: every half-moved state looked like a real change,
    /// so the space indicator and layout chased each one, and a Desktop
    /// emptied mid-shuffle could even be auto-deleted.
    private var isReorderingSpaces = false
    /// The latest queued reorder; the next one waits for it.
    private var reorderTask: Task<Void, Never>?
    private var pendingReorders = 0
    private var lastWindowSignature = ""
    private var pendingForcedLayout = false
    /// Set when a refresh was dropped for a transient reason (a display or
    /// frame animation, Mission Control, a held mouse button). The poll only
    /// refreshes on a changed window signature, and the signature was often
    /// taken already — an app quitting mid-animation then left its neighbour
    /// stuck at half width until something else moved.
    private var refreshDeferred = false
    private var idlePollSkips = 0
    private var started = false

    private init(settings: AppSettings) {
        self.settings = settings
        controlBar.mode = settings.tilingControlBarMode
        controlBar.isEnabled = settings.tilingShowControlBar
        controlBar.onRetile = { [weak self] in self?.retile() }
        controlBar.onTogglePause = { [weak self] displayUUID in self?.togglePause(displayUUID: displayUUID) }
        controlBar.onToggleMaster = { [weak self] displayUUID, winID in
            self?.toggleMainTabGroup(displayUUID: displayUUID, windowID: winID)
        }
        controlBar.onToggleFloating = { [weak self] displayUUID, winID in self?.toggleFloating(displayUUID: displayUUID, windowID: winID) }
        controlBar.onActivateWindow = { [weak self] windowID, pid, frame in
            self?.activateWindow(windowID: windowID, pid: pid, frame: frame)
        }
        controlBar.onToggleScope = { [weak self] in
            guard let self else { return }
            let current = self.settings.tilingControlBarScope
            self.settings.tilingControlBarScope = (current == .allSpaces) ? .currentSpace : .allSpaces
            self.refreshNow(forceLayout: false)
        }
        controlBar.onSwitchSpace = { [weak self] displayUUID, spaceNum in
            self?.switchToSpace(displayUUID: displayUUID, spaceNumber: spaceNum)
        }
        controlBar.onDeleteSpace = { [weak self] displayUUID, spaceNum in
            self?.deleteSpace(displayUUID: displayUUID, spaceNumber: spaceNum)
        }
        controlBar.onAddSpace = { [weak self] displayUUID in
            self?.addSpace(displayUUID: displayUUID)
        }
        controlBar.onReorderSpaces = { [weak self] displayUUID, moves, show in
            guard #available(macOS 14.0, *) else { return }
            self?.reorderSpaces(displayUUID: displayUUID, moves: moves, show: show)
        }
        controlBar.onWindowMovedToSpace = { [weak self] _, spaceID in
            self?.scheduleRefresh(after: 0.1)
            // After that refresh has started retiling the Desktop it left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.layoutSpaceAfterDrop(Int(spaceID))
            }
        }
        let swipes = TrackpadSwipeMonitor.shared
        swipes.onVerticalSwipeBegan = { [weak self] in self?.tabSwipeBegan() }
        swipes.onVerticalSwipeChanged = { [weak self] offset in
            guard #available(macOS 14.0, *) else { return }
            (self?.tabSwitcherStorage as? TilingTabSwitcher)?.change(offset)
        }
        swipes.onVerticalSwipeEnded = { [weak self] in
            guard #available(macOS 14.0, *) else { return }
            (self?.tabSwitcherStorage as? TilingTabSwitcher)?.end()
        }
        swipes.onHorizontalSwipeBegan = { [weak self] in self?.spaceSwipeBegan() }
        swipes.onHorizontalSwipeChanged = { [weak self] offset, rise in
            guard #available(macOS 14.0, *) else { return }
            (self?.spaceSwitcherStorage as? TilingSpaceSwitcher)?.change(offset, rise: rise)
        }
        swipes.onHorizontalSwipeEnded = { [weak self] in
            guard #available(macOS 14.0, *) else { return }
            (self?.spaceSwitcherStorage as? TilingSpaceSwitcher)?.end()
        }

        resizeOverlay.onResizeStart = { [weak self] divider in
            self?.handleOverlayResizeStart(divider: divider)
        }
        resizeOverlay.onResizeDrag = { [weak self] divider, coordinate in
            self?.scheduleOverlayResize(divider: divider, coordinate: coordinate)
        }
        resizeOverlay.onResizeEnd = { [weak self] in
            self?.flushOverlayResize()
            self?.handleOverlayResizeEnd()
        }
    }

    func start() {
        guard !started else { settingsChanged(); return }
        started = true
        let workspaceNC = NSWorkspace.shared.notificationCenter
        observations.append(workspaceNC.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !SystemSearchOverlay.isAbout(note) else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication {
                self.handleNewApplicationLaunch(app)
            }
            self.scheduleRefresh(after: 0.08)
        })
        // A quitting app's windows can outlive the notification by a moment
        // (close animation, WindowServer teardown); look again once they're gone.
        observations.append(workspaceNC.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.scheduleRefresh(after: 0) }
        })
        for name in [NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observations.append(workspaceNC.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard !SystemSearchOverlay.isAbout(note) else { return }
                self?.scheduleRefresh(after: 0.08)
            })
        }
        observations.append(workspaceNC.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSpaceChange()
        })
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelFrameAnimations()
            self?.resizeStart = nil
            self?.handleDragSession = nil
            self?.lastWindowSignature = ""
            self?.scheduleRefresh(after: 0.25)
        })
        PresentationState.shared.addObserver { [weak self] in
            self?.applyRunningState()
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
            guard let self, self.started, self.settings.tilingEnabled else { return }
            if event.type == .mouseMoved {
                self.resizeOverlay.handleMouseMove(at: NSEvent.mouseLocation)
            } else if event.type == .leftMouseDown {
                self.beginMouseResize()
            } else if event.type == .leftMouseDragged {
                self.scheduleLiveResize()
            } else {
                self.dropPoint = NSEvent.mouseLocation
                self.resizeWork?.cancel()
                self.resizeWork = nil
                if self.commitColumnDropFromGesture() {
                    self.resizeStart = nil
                }
                self.resizeOverlay.notifyDragEnded()
                self.scheduleRefresh(after: 0.06)
            }
        }
        applyRunningState()
    }

    func stop() {
        refreshWork?.cancel()
        refreshWork = nil
        spaceSettlingWork?.cancel()
        spaceSettlingWork = nil
        isSettlingSpaceSwitch = false
        pollTimer?.invalidate()
        pollTimer = nil
        observations.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observations = []
        controlBar.stop()
        resizeOverlay.stop()
        TrackpadSwipeMonitor.shared.stop()
        if #available(macOS 14.0, *) {
            (tabSwitcherStorage as? TilingTabSwitcher)?.cancel()
            (spaceSwitcherStorage as? TilingSpaceSwitcher)?.cancel()
        }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        resizeStart = nil
        handleDragSession = nil
        resizeWork?.cancel()
        resizeWork = nil
        overlayResizeWork?.cancel()
        overlayResizeWork = nil
        pendingOverlayResize = nil
        cancelFrameAnimations()
        framePipeline.shutdown()
        menuBar.setEnabled(false)
        allBarWindowCache.removeAll()
        orderedWindowIDsBySpace.removeAll()
        visibleWindowLastSeenAt.removeAll()
        emptySpaceSince.removeAll()
        isRemovingEmptySpace = false
        appIsolationWorkByPID.values.forEach { $0.cancel() }
        appIsolationWorkByPID.removeAll()
        appsBeingIsolated.removeAll()
        programmaticTargetSpaceByDisplay.removeAll()
        nativeSpaceSwitchGeneration &+= 1
        started = false
    }

    func settingsChanged() {
        applyRunningState()
        if !automaticallyRemovesEmptySpaces {
            emptySpaceSince.removeAll()
        }
        if !settings.tilingOneAppPerDeskspace {
            appIsolationWorkByPID.values.forEach { $0.cancel() }
            appIsolationWorkByPID.removeAll()
            appsBeingIsolated.removeAll()
        }
        if settings.tilingEnabled {
            lastWindowSignature = ""
            refreshNow(forceLayout: true)
        }
    }

    func retile() {
        NSLog("MSG Tiling: retile called")
        lastWindowSignature = ""
        refreshNow(forceLayout: true)
        DispatchQueue.main.async { [weak self] in
            self?.refreshNow(forceLayout: true)
        }
    }

    func togglePauseCurrentSpace() { togglePause(displayUUID: focusedDisplayUUID()) }

    /// The swipe tab switcher, loosely typed: a stored property can't carry
    /// an availability gate, and its cards need macOS 14.
    private var tabSwitcherStorage: AnyObject?

    @available(macOS 14.0, *)
    private var tabSwitcher: TilingTabSwitcher {
        if let existing = tabSwitcherStorage as? TilingTabSwitcher { return existing }
        let created = TilingTabSwitcher()
        created.activate = { [weak self] window, displayUUID in
            self?.controlBar.activateTab(window, displayUUID: displayUUID)
        }
        created.isMissionControlActive = { MissionControlDetector.isActive() }
        tabSwitcherStorage = created
        return created
    }

    /// A vertical swipe starting: the tabs on the display under the pointer —
    /// where the user is looking — are the ones it flips through.
    private func tabSwipeBegan() {
        guard #available(macOS 14.0, *) else { return }
        guard started, settings.tilingEnabled, settings.tilingSwipeCyclesTabs,
              !MissionControlDetector.isActive() else { return }
        let pointer = NSEvent.mouseLocation
        let displayUUID = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(pointer) }?.uuid
            ?? focusedDisplayUUID()
        guard let displayUUID, let group = controlBar.tabGroup(displayUUID: displayUUID, pointer: pointer) else { return }
        tabSwitcher.begin(group)
    }

    /// The swipe deskspace switcher, loosely typed for macOS 14 availability.
    private var spaceSwitcherStorage: AnyObject?

    @available(macOS 14.0, *)
    private var spaceSwitcher: TilingSpaceSwitcher {
        if let existing = spaceSwitcherStorage as? TilingSpaceSwitcher { return existing }
        let created = TilingSpaceSwitcher()
        created.onSwitchSpace = { [weak self] displayUUID, spaceNumber in
            self?.switchToSpace(displayUUID: displayUUID, spaceNumber: spaceNumber)
        }
        created.onDeleteSpace = { [weak self] displayUUID, spaceNumber, windows in
            self?.closeWindowsAndDeleteSpace(displayUUID: displayUUID, spaceNumber: spaceNumber, windows: windows)
        }
        created.onReorderSpaces = { [weak self] displayUUID, moves, show in
            self?.reorderSpaces(displayUUID: displayUUID, moves: moves, show: show)
        }
        created.isMissionControlActive = { MissionControlDetector.isActive() }
        spaceSwitcherStorage = created
        return created
    }

    /// A horizontal swipe starting: switches deskspaces on the display under the pointer.
    private func spaceSwipeBegan() {
        guard #available(macOS 14.0, *) else { return }
        guard started, settings.tilingEnabled, settings.tilingSwipeSwitchesSpaces,
              !MissionControlDetector.isActive() else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen, let displayUUID = screen.uuid ?? focusedDisplayUUID() else { return }
        let spaces = WindowPreviewCapture.managedSpaces(for: screen)
        guard spaces.count > 1 else { return }
        let currentID = WindowPreviewCapture.currentManagedSpaceID(for: screen)
        let currentIndex = spaces.firstIndex(where: { $0.id == currentID }) ?? 0
        spaceSwitcher.begin(screen: screen, displayUUID: displayUUID, spaces: spaces, initialIndex: currentIndex)
    }
    func makeFocusedWindowMain() { makeMaster(displayUUID: focusedDisplayUUID()) }
    func toggleFloatingForFocusedWindow() { toggleFloating(displayUUID: focusedDisplayUUID()) }

    private func applyRunningState() {
        // Temporary Mission Control/fullscreen suppression does not relinquish
        // the global preference; disable/quit does.
        controlBar.mode = settings.tilingControlBarMode
        let menuBarOverride: Bool? = started && settings.tilingEnabled
            ? settings.tilingControlBarMode == .fullWidth
            : nil
        menuBar.setAutoHideOverride(menuBarOverride)
        let shouldRun = started && settings.tilingEnabled && PresentationState.shared.canPresent
        if shouldRun {
            if pollTimer == nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    // With no input for a while windows rarely change by
                    // themselves, and launches, quits and activations refresh
                    // through notifications anyway: poll ~1×/s instead of 4×.
                    let idle = CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
                    if idle > 5, !self.refreshDeferred, !self.pendingForcedLayout {
                        self.idlePollSkips += 1
                        guard self.idlePollSkips >= 4 else { return }
                    }
                    self.idlePollSkips = 0
                    self.pollForChanges()
                }
                timer.tolerance = 0.05
                RunLoop.main.add(timer, forMode: .common)
                pollTimer = timer
            }
            controlBar.isEnabled = settings.tilingShowControlBar
            if settings.tilingShowControlBar {
                controlBar.start()
            } else {
                controlBar.stop()
            }
            resizeOverlay.start()
            if settings.tilingSwipeCyclesTabs || settings.tilingSwipeSwitchesSpaces {
                TrackpadSwipeMonitor.shared.setHorizontalFingers(settings.tilingSpaceSwipeFingers)
                TrackpadSwipeMonitor.shared.setVerticalEnabled(settings.tilingSwipeCyclesTabs)
                TrackpadSwipeMonitor.shared.start()
            } else {
                TrackpadSwipeMonitor.shared.stop()
                if #available(macOS 14.0, *) {
                    (tabSwitcherStorage as? TilingTabSwitcher)?.cancel()
                    (spaceSwitcherStorage as? TilingSpaceSwitcher)?.cancel()
                }
            }
            scheduleRefresh(after: 0)
        } else {
            TrackpadSwipeMonitor.shared.stop()
            if #available(macOS 14.0, *) {
                (tabSwitcherStorage as? TilingTabSwitcher)?.cancel()
                (spaceSwitcherStorage as? TilingSpaceSwitcher)?.cancel()
            }
            pollTimer?.invalidate()
            pollTimer = nil
            refreshWork?.cancel()
            refreshWork = nil
            spaceSettlingWork?.cancel()
            spaceSettlingWork = nil
            isSettlingSpaceSwitch = false
            resizeStart = nil
            handleDragSession = nil
            cancelFrameAnimations()
            controlBar.stop()
            resizeOverlay.stop()
        }
    }

    private func handleSpaceChange() {
        cancelFrameAnimations()
        resizeStart = nil
        handleDragSession = nil
        resizeWork?.cancel()
        resizeWork = nil
        overlayResizeWork?.cancel()
        overlayResizeWork = nil
        pendingOverlayResize = nil
        controlBar.handleSpaceChange()
        updateControlBarSpaces()
        isSettlingSpaceSwitch = true
        spaceSettlingWork?.cancel()
        refreshWork?.cancel()
        refreshWork = nil

        func scheduleSettlingCheck(attempt: Int) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.isAnyDisplayAnimating() && attempt < 15 {
                    scheduleSettlingCheck(attempt: attempt + 1)
                    return
                }
                self.isSettlingSpaceSwitch = false
                self.spaceSettlingWork = nil
                self.programmaticTargetSpaceByDisplay.removeAll()
                self.lastWindowSignature = ""
                self.refreshNow(forceLayout: false)
                // Some apps, especially Gemini, briefly disappear from AX/CG
                // enumeration just after the Space animation lands. Re-read
                // once WindowServer has had time to publish the settled list.
                self.scheduleRefresh(after: 0.35)
            }
            self.spaceSettlingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.20 : 0.08), execute: work)
        }
        scheduleSettlingCheck(attempt: 0)
    }

    private func updateControlBarSpaces() {
        guard started, settings.tilingEnabled, PresentationState.shared.canPresent else { return }
        guard settings.tilingShowControlBar else { return }
        let spaces = visibleSpaces()
        var updatedSnapshots: [TilingBarSnapshot] = []
        for space in spaces {
            guard !space.isFullscreen else { continue }
            let state = workspaceState(for: space.key)
            let previous = controlBar.snapshot(for: space.key.displayUUID)
            let sNum = pendingProgrammaticTarget(for: space.key.displayUUID, current: space.number)
                ?? space.number
            let priorWindows = previous?.windows ?? []
            var earlyWindows = priorWindows
            if settings.tilingPillScope == .currentSpace,
               let targetShown = cachedShownWindowIDs(
                    displayUUID: space.key.displayUUID,
                    spaceNumber: sNum,
                    visibleSpace: space
               ) {
                if settings.tilingControlBarScope == .currentSpace {
                    let orderKey = "\(space.key.displayUUID.lowercased())_\(sNum)"
                    let cachedTargetWindows = (orderedWindowIDsBySpace[orderKey] ?? []).compactMap {
                        allBarWindowCache[$0]?.window
                    }
                    if !cachedTargetWindows.isEmpty {
                        earlyWindows = cachedTargetWindows
                    }
                }
                earlyWindows = earlyWindows.map {
                    $0.withShownInLayout(targetShown.contains($0.windowID))
                }
            }
            updatedSnapshots.append(TilingBarSnapshot(
                displayUUID: space.key.displayUUID,
                spaceNumber: sNum,
                spaceCount: space.total,
                mode: state.mode,
                paused: state.paused,
                windows: earlyWindows,
                focusedStatus: previous?.focusedStatus ?? .split,
                focusedIsFloating: previous?.focusedIsFloating ?? false,
                scope: settings.tilingControlBarScope,
                pillScope: settings.tilingPillScope
            ))
        }
        if !updatedSnapshots.isEmpty {
            controlBar.update(updatedSnapshots)
        }
    }

    /// Returns the last known visible left/right windows for the destination
    /// Deskspace so the pill can begin moving in the first bar-only update,
    /// without waiting for the slower layout reconciliation pass.
    private func cachedShownWindowIDs(displayUUID: String, spaceNumber: Int,
                                      visibleSpace: TilingVisibleSpace) -> Set<CGWindowID>? {
        if visibleSpace.number == spaceNumber,
           let known = shownWindowIDsBySpace[visibleSpace.key], !known.isEmpty {
            return known
        }

        let orderKey = "\(displayUUID.lowercased())_\(spaceNumber)"
        let cachedWindows = (orderedWindowIDsBySpace[orderKey] ?? []).compactMap {
            allBarWindowCache[$0]?.window
        }
        guard !cachedWindows.isEmpty else { return nil }
        let main = cachedWindows.first(where: {
            $0.status == .leftTabbed && $0.isShownInLayout
        }) ?? cachedWindows.first(where: { $0.status == .leftTabbed }) ??
            cachedWindows.first(where: { $0.status != .floating })
        let right = cachedWindows.first(where: {
            $0.status == .rightTabbed && $0.isShownInLayout
        }) ?? cachedWindows.first(where: { $0.status == .rightTabbed })
        let ids = Set([main?.windowID, right?.windowID].compactMap { $0 })
        return ids.isEmpty ? nil : ids
    }

    private func isAnyDisplayAnimating() -> Bool {
        let cid = TilingCGSMainConnectionID()
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid else { continue }
            if TilingCGSManagedDisplayIsAnimating(cid, uuid as CFString) {
                return true
            }
        }
        return false
    }

    private func pollForChanges() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        // During space settling, skip CGS queries to keep the main thread free
        // for control bar pill/app animations.
        guard !isSettlingSpaceSwitch, !isReorderingSpaces, !isAnyDisplayAnimating() else { return }
        scanForEmptySpacesIfNeeded()
        if settings.tilingShowControlBar {
            let spaces = visibleSpaces()
            if spaces.contains(where: { controlBar.snapshot(for: $0.key.displayUUID)?.spaceNumber != $0.number }) {
                updateControlBarSpaces()
            }
        }
        let signature = currentWindowSignature()
        guard signature != "mission_control" else {
            lastWindowSignature = signature
            return
        }
        guard pendingForcedLayout || refreshDeferred || signature != lastWindowSignature else {
            if settings.tilingShowControlBar {
                controlBar.refreshVisibility()
            }
            return
        }
        lastWindowSignature = signature
        refreshNow(forceLayout: false)
    }

    private var automaticallyRemovesEmptySpaces: Bool {
        settings.tilingAutoDeleteEmptySpaces || settings.tilingOneAppPerDeskspace
    }

    private func handleNewApplicationLaunch(_ app: NSRunningApplication) {
        guard started, settings.tilingEnabled, settings.tilingOneAppPerDeskspace,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, !SystemSearchOverlay.contains(app) else { return }
        scheduleAppIsolation(pid: app.processIdentifier, attempt: 0, after: 0.15)
    }

    /// App launch arrives before many apps publish their first AX window. Poll
    /// briefly, then make exactly one routing decision for that process. This is
    /// deliberately not a continuous invariant: a later user move may combine
    /// apps on one Deskspace and MSG will respect it.
    private func scheduleAppIsolation(pid: pid_t, attempt: Int, after delay: TimeInterval) {
        guard attempt < 80 else {
            appIsolationWorkByPID.removeValue(forKey: pid)
            appsBeingIsolated.remove(pid)
            return
        }
        appIsolationWorkByPID[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appIsolationWorkByPID.removeValue(forKey: pid)
            self.attemptAppIsolation(pid: pid, attempt: attempt)
        }
        appIsolationWorkByPID[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attemptAppIsolation(pid: pid_t, attempt: Int) {
        guard started, settings.tilingEnabled, settings.tilingOneAppPerDeskspace,
              AXIsProcessTrusted(),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            appsBeingIsolated.remove(pid)
            return
        }
        guard !appsBeingIsolated.contains(pid) else { return }
        guard !isRemovingEmptySpace, !isReorderingSpaces,
              !MissionControlDetector.isActive(), !isAnyDisplayAnimating() else {
            scheduleAppIsolation(pid: pid, attempt: attempt + 1, after: 0.15)
            return
        }

        let allWindows = visibleWindows()
        let appWindows = allWindows.filter { $0.pid == pid }
        guard let anchor = appWindows.first else {
            scheduleAppIsolation(pid: pid, attempt: attempt + 1, after: 0.10)
            return
        }
        guard let sourceSpace = visibleSpaces().first(where: { space in
            space.key.displayUUID.caseInsensitiveCompare(anchor.displayUUID) == .orderedSame &&
                (anchor.spaceIDs.isEmpty || anchor.spaceIDs.contains(space.key.spaceID))
        }) else {
            scheduleAppIsolation(pid: pid, attempt: attempt + 1, after: 0.10)
            return
        }

        let hasOtherApplication = allWindows.contains { window in
            window.pid != pid &&
                window.displayUUID.caseInsensitiveCompare(sourceSpace.key.displayUUID) == .orderedSame &&
                (window.spaceIDs.isEmpty || window.spaceIDs.contains(sourceSpace.key.spaceID))
        }
        guard TilingLayout.shouldCreateDeskspaceForNewApp(
            hasUsableWindow: true,
            currentSpaceIsFullscreen: sourceSpace.isFullscreen,
            hasOtherApplication: hasOtherApplication
        ) else {
            // Choice 1: this Deskspace was empty, so the new app keeps it.
            return
        }

        appsBeingIsolated.insert(pid)
        let sourceSpaceID = UInt64(sourceSpace.key.spaceID)
        let displayUUID = sourceSpace.key.displayUUID
        let shouldFollowApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        addSpace(displayUUID: displayUUID) { [weak self] targetSpaceID in
            guard let self else { return }
            guard let targetSpaceID else {
                self.appsBeingIsolated.remove(pid)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let candidates = WindowPreviewCapture.switcherWindows(pid: pid, scriptBrowsers: false)
                    .filter {
                        $0.id != 0 && WindowPreviewCapture.window(
                            $0.id, isOnManagedSpace: sourceSpaceID
                        )
                    }
                var moved: [CapturedWindow] = []
                for window in candidates {
                    if await WindowPreviewCapture.moveWindow(window.id, toManagedSpace: targetSpaceID) {
                        moved.append(window)
                    }
                }
                // Follow only a foreground launch. Background launches are
                // isolated without stealing focus from what the user is doing.
                if #available(macOS 14.0, *), shouldFollowApp, let first = moved.first {
                    await WindowPreviewCapture.raiseWindow(
                        pid: pid, windowID: first.id, fallbackBounds: first.bounds
                    )
                }
                self.appsBeingIsolated.remove(pid)
                self.lastWindowSignature = ""
                self.scheduleRefresh(after: 0.25)
            }
        }
    }

    private func scanForEmptySpacesIfNeeded() {
        guard automaticallyRemovesEmptySpaces, !isRemovingEmptySpace else { return }
        // The cheap throttle first: this runs on every 0.25 s poll, and the
        // Mission Control check is a window-list pass.
        let now = CACurrentMediaTime()
        guard now - lastEmptySpaceScanAt >= 2.0, !MissionControlDetector.isActive() else { return }
        lastEmptySpaceScanAt = now
        guard let rawDisplays = TilingCGSCopyManagedDisplaySpaces(TilingCGSMainConnectionID())
                as? [[String: Any]] else { return }

        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid
        let applicationWindowIDs = eligibleApplicationWindowIDs()
        var continuouslyEmpty = Set<Int>()
        var ready: [EmptySpaceCandidate] = []

        for display in rawDisplays {
            var displayUUID = display["Display Identifier"] as? String ?? ""
            if displayUUID == "Main" { displayUUID = primaryUUID ?? "" }
            guard let screen = NSScreen.screens.first(where: {
                $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
            }), let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else { continue }

            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            let currentID = (display["Current Space"] as? [String: Any]).map(managedSpaceID) ?? 0
            let userSpaceCount = spaces.filter { ($0["type"] as? Int ?? 0) == 0 }.count
            for (index, space) in spaces.enumerated() {
                let spaceID = managedSpaceID(space)
                let isUserSpace = (space["type"] as? Int ?? 0) == 0
                guard spaceID > 0, isUserSpace, spaceID != currentID, userSpaceCount > 1 else {
                    emptySpaceSince.removeValue(forKey: spaceID)
                    continue
                }
                let hasWindows = spaceContainsApplicationWindows(
                    spaceID: spaceID, applicationWindowIDs: applicationWindowIDs
                )
                guard !hasWindows else {
                    emptySpaceSince.removeValue(forKey: spaceID)
                    continue
                }
                continuouslyEmpty.insert(spaceID)
                let emptySince = emptySpaceSince[spaceID] ?? now
                emptySpaceSince[spaceID] = emptySince
                if TilingLayout.shouldAutoRemoveSpace(
                    isUserSpace: true, isCurrent: false, userSpaceCount: userSpaceCount,
                    hasApplicationWindows: false, emptyDuration: now - emptySince
                ) {
                    ready.append(EmptySpaceCandidate(
                        displayUUID: displayUUID, displayID: displayID,
                        spaceID: spaceID, spaceIndex: index, spaceCount: spaces.count
                    ))
                }
            }
        }

        emptySpaceSince = emptySpaceSince.filter { continuouslyEmpty.contains($0.key) }
        // Highest indices first keep the remaining Deskspace numbering stable.
        if let candidate = ready.max(by: { $0.spaceIndex < $1.spaceIndex }) {
            removeEmptySpace(candidate)
        }
    }

    /// Smallest window, on either side, that makes a Deskspace count as used.
    private static let minimumOccupyingWindowSide: CGFloat = 40

    private func eligibleApplicationWindowIDs() -> Set<CGWindowID> {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let regularPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard app.activationPolicy == .regular, app.processIdentifier != myPID else { return nil }
            return app.processIdentifier
        })
        guard let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(windows.compactMap { info -> CGWindowID? in
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  regularPIDs.contains(pid),
                  (info[kCGWindowLayer as String] as? Int ?? -1) == 0 else { return nil }
            // Apps park invisible helper windows on a Space — ChatGPT keeps a
            // 1x1 one — and those alone must not make a Deskspace count as used.
            let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= Self.minimumOccupyingWindowSide,
                  bounds.height >= Self.minimumOccupyingWindowSide,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return windowID
        })
    }

    private func spaceContainsApplicationWindows(spaceID: Int,
                                                 applicationWindowIDs: Set<CGWindowID>) -> Bool {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaces = [NSNumber(value: UInt64(spaceID))] as CFArray
        guard let raw = TilingSLSCopyWindowsWithOptionsAndTags(
            TilingCGSMainConnectionID(), 0, spaces, 0x7, &setTags, &clearTags
        ) as? [NSNumber] else {
            // An uncertain read is never permission to delete a Deskspace.
            return true
        }
        return raw.contains { applicationWindowIDs.contains(CGWindowID($0.uint32Value)) }
    }

    private func removeEmptySpace(_ candidate: EmptySpaceCandidate) {
        guard started, automaticallyRemovesEmptySpaces else { return }
        isRemovingEmptySpace = true
        emptySpaceSince.removeValue(forKey: candidate.spaceID)
        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: missionControlURL, configuration: configuration) {
            [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    self.finishEmptySpaceRemoval(success: false)
                    return
                }
                self.performEmptySpaceRemoval(candidate, attempt: 0)
            }
        }
    }

    private func performEmptySpaceRemoval(_ candidate: EmptySpaceCandidate, attempt: Int) {
        guard started, automaticallyRemovesEmptySpaces else {
            finishEmptySpaceRemoval(success: false)
            return
        }
        if attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.performEmptySpaceRemoval(candidate, attempt: attempt + 1)
            }
            return
        }
        if let button = missionControlSpaceButton(displayID: candidate.displayID,
                                                  spaceIndex: candidate.spaceIndex,
                                                  expectedCount: candidate.spaceCount) {
            let result = AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString)
            finishEmptySpaceRemoval(success: result == .success)
            return
        }
        guard attempt < 20 else {
            finishEmptySpaceRemoval(success: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performEmptySpaceRemoval(candidate, attempt: attempt + 1)
        }
    }

    /// Adds a Desktop to a display the only way macOS allows another app to:
    /// Mission Control's own "add desktop" button, pressed through
    /// accessibility, then Mission Control closed again.
    func addSpace(displayUUID: String) {
        addSpace(displayUUID: displayUUID) { _ in }
    }

    private func addSpace(displayUUID: String,
                          completion: @escaping (UInt64?) -> Void) {
        guard started, !isRemovingEmptySpace,
              let screen = NSScreen.screens.first(where: {
                  $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
              }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else {
            completion(nil)
            return
        }
        let existingSpaceIDs = Set(WindowPreviewCapture.managedSpaces(for: screen).map(\.id))
        // Shares the removal flag: both drive Mission Control, and neither may
        // start while the other has it open.
        isRemovingEmptySpace = true
        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: missionControlURL, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    self.finishEmptySpaceRemoval(success: false) { completion(nil) }
                    return
                }
                self.performSpaceAddition(
                    displayID: displayID,
                    screen: screen,
                    existingSpaceIDs: existingSpaceIDs,
                    attempt: 0,
                    completion: completion
                )
            }
        }
    }

    private func performSpaceAddition(displayID: CGDirectDisplayID,
                                      screen: NSScreen,
                                      existingSpaceIDs: Set<UInt64>,
                                      attempt: Int,
                                      completion: @escaping (UInt64?) -> Void) {
        guard started else {
            finishEmptySpaceRemoval(success: false) { completion(nil) }
            return
        }
        if let button = missionControlAddSpaceButton(displayID: displayID) {
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else {
                finishEmptySpaceRemoval(success: false) { completion(nil) }
                return
            }
            waitForAddedSpace(
                screen: screen,
                existingSpaceIDs: existingSpaceIDs,
                attempt: 0,
                completion: completion
            )
            return
        }
        guard attempt < 20 else {
            finishEmptySpaceRemoval(success: false) { completion(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performSpaceAddition(
                displayID: displayID,
                screen: screen,
                existingSpaceIDs: existingSpaceIDs,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    /// The accessibility press returns before WindowServer publishes the new
    /// managed-space id. Wait for the concrete id so launch routing never moves
    /// a window to a guessed or renumbered Deskspace.
    private func waitForAddedSpace(screen: NSScreen,
                                   existingSpaceIDs: Set<UInt64>,
                                   attempt: Int,
                                   completion: @escaping (UInt64?) -> Void) {
        let newSpace = WindowPreviewCapture.managedSpaces(for: screen).first {
            !existingSpaceIDs.contains($0.id) && !$0.isFullscreen
        }
        if let newSpace {
            finishEmptySpaceRemoval(success: true) { completion(newSpace.id) }
            return
        }
        guard attempt < 20 else {
            finishEmptySpaceRemoval(success: false) { completion(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForAddedSpace(
                screen: screen,
                existingSpaceIDs: existingSpaceIDs,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    /// Mission Control's "add desktop" button for a display, found where
    /// `missionControlSpaceButton` finds the Spaces Bar.
    private func missionControlAddSpaceButton(displayID: CGDirectDisplayID) -> AXUIElement? {
        for bundleID in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let host = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }) else { continue }
            let root = AXUIElementCreateApplication(host.processIdentifier)
            guard let display = findAXDescendant(in: root, identifier: "mc.display",
                                                 displayID: displayID, depth: 3),
                  let button = findAXDescendant(in: display, identifier: "mc.spaces.add",
                                                depth: 4) else { continue }
            return button
        }
        return nil
    }

    /// Hold-to-delete from the swipe HUD: closes the Desktop's windows, then
    /// removes the Desktop. A window that won't close (an unsaved-changes
    /// sheet, say) doesn't stop the delete; macOS moves it to a neighbouring
    /// Desktop along with the removal.
    @available(macOS 14.0, *)
    func closeWindowsAndDeleteSpace(displayUUID: String, spaceNumber: Int, windows: [NotchWindowItem]) {
        guard !windows.isEmpty else {
            let pendingReorder = reorderTask
            Task { @MainActor [weak self] in
                await pendingReorder?.value
                self?.deleteSpace(displayUUID: displayUUID, spaceNumber: spaceNumber)
            }
            return
        }
        guard let screen = NSScreen.screens.first(where: {
                  $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
              }),
              let spaceID = WindowPreviewCapture.managedSpace(for: screen, number: spaceNumber)?.id else { return }
        let pendingReorder = reorderTask
        Task { @MainActor [weak self] in
            // Reorders placed earlier in the same swipe land first.
            await pendingReorder?.value
            await withTaskGroup(of: Void.self) { group in
                for window in windows {
                    group.addTask { await WindowPreviewCapture.closeWindow(pid: window.pid, windowID: window.id) }
                }
            }
            // Give apps a moment to actually close; stop early once they have.
            let ids = Set(windows.map(\.id))
            for _ in 0..<15 {
                let open = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .contains { ($0[kCGWindowNumber as String] as? CGWindowID).map(ids.contains) ?? false }
                guard open else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Closing can't renumber Desktops, but look the Space up again by
            // id in case something else did meanwhile.
            guard let self,
                  let number = WindowPreviewCapture.managedSpaces(for: screen).firstIndex(where: { $0.id == spaceID })
            else { return }
            self.deleteSpace(displayUUID: displayUUID, spaceNumber: number + 1)
        }
    }

    /// Reorders a display's Desktops by moving their windows, since macOS has
    /// no API to reorder Spaces. Each move, in order, takes the Desktop at
    /// `from` to position `to` (1-based, against the order the previous move
    /// left); the ones between shift one place toward `from`. Space ids stay
    /// where they are; only their contents change.
    ///
    /// `show`: the position to be on afterwards. The display switches there
    /// *before* any window moves, so the Desktop in view never visibly swaps
    /// contents under the user — the contents arrive where they already are.
    ///
    /// Batches run one after another, each seeing the Desktops as the
    /// previous one left them.
    @available(macOS 14.0, *)
    func reorderSpaces(displayUUID: String, moves: [(from: Int, to: Int)], show: Int?) {
        let moves = moves.filter { $0.from != $0.to }
        guard !moves.isEmpty || show != nil else { return }
        let previous = reorderTask
        pendingReorders += 1
        isReorderingSpaces = true
        reorderTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if let show { await self.switchAndLand(displayUUID: displayUUID, spaceNumber: show) }
            for move in moves {
                await self.performReorder(displayUUID: displayUUID, from: move.from, to: move.to)
            }
            self.pendingReorders -= 1
            guard self.pendingReorders == 0 else { return }
            // One settled refresh once everything has landed.
            self.isReorderingSpaces = false
            self.lastWindowSignature = ""
            self.updateControlBarSpaces()
            self.refreshNow(forceLayout: true)
        }
    }

    /// Switches the display to a Desktop and waits (briefly) for it to land.
    @available(macOS 14.0, *)
    private func switchAndLand(displayUUID: String, spaceNumber: Int) async {
        guard let screen = NSScreen.screens.first(where: {
                  $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
              }),
              let target = WindowPreviewCapture.managedSpace(for: screen, number: spaceNumber),
              WindowPreviewCapture.currentManagedSpaceID(for: screen) != target.id else { return }
        switchToSpace(displayUUID: displayUUID, spaceNumber: spaceNumber)
        for _ in 0..<30 {
            if WindowPreviewCapture.currentManagedSpaceID(for: screen) == target.id,
               !isAnyDisplayAnimating() { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @available(macOS 14.0, *)
    private func performReorder(displayUUID: String, from: Int, to: Int) async {
        guard let screen = NSScreen.screens.first(where: {
            $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
        }) else { return }
        let spaces = WindowPreviewCapture.managedSpaces(for: screen)
        let lo = min(from, to) - 1, hi = max(from, to) - 1
        guard lo >= 0, hi < spaces.count,
              !spaces[lo...hi].contains(where: \.isFullscreen) else { return }
        // The new order of contents across lo...hi.
        var order = Array(lo...hi)
        let moved = order.remove(at: from - 1 - lo)
        order.insert(moved, at: to - 1 - lo)

        // Snapshot every Desktop's windows before anything moves.
        let contents: [[CGWindowID]] = await Task.detached(priority: .userInitiated) {
            (lo...hi).map { index in
                WindowPreviewCapture.scanScreenWindows(screen: screen, onSpace: spaces[index].id,
                                                       maxWindows: 500).items.map(\.id)
            }
        }.value

        await withTaskGroup(of: Void.self) { group in
            for (slot, source) in order.enumerated() where source != lo + slot {
                let target = spaces[lo + slot].id
                for window in contents[source - lo] {
                    group.addTask { _ = await WindowPreviewCapture.moveWindow(window, toManagedSpace: target) }
                }
            }
        }

        for index in lo...hi { TilingSpacePreviewCache.captures.removeValue(forKey: spaces[index].id) }
    }

    func deleteSpace(displayUUID: String, spaceNumber: Int) {
        guard started, !isRemovingEmptySpace else { return }
        guard let display = managedDisplay(displayUUID),
              let spaces = display["Spaces"] as? [[String: Any]],
              spaceNumber >= 1, spaceNumber <= spaces.count,
              spaces.count > 1 else { return }

        let spaceIndex = spaceNumber - 1
        let space = spaces[spaceIndex]
        let spaceID = managedSpaceID(space)

        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid
        var resolvedUUID = display["Display Identifier"] as? String ?? ""
        if resolvedUUID == "Main" { resolvedUUID = primaryUUID ?? "" }
        guard let screen = NSScreen.screens.first(where: {
            $0.uuid?.caseInsensitiveCompare(resolvedUUID) == .orderedSame
        }), let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }

        isRemovingEmptySpace = true
        emptySpaceSince.removeValue(forKey: spaceID)
        programmaticTargetSpaceByDisplay.removeValue(forKey: displayUUID.lowercased())
        programmaticTargetSetAt.removeValue(forKey: displayUUID.lowercased())

        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: missionControlURL, configuration: configuration) {
            [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil else {
                    self.finishEmptySpaceRemoval(success: false)
                    return
                }
                self.performExplicitSpaceRemoval(displayID: displayID, spaceIndex: spaceIndex, attempt: 0)
            }
        }
    }

    private func performExplicitSpaceRemoval(displayID: CGDirectDisplayID, spaceIndex: Int, attempt: Int) {
        guard started else {
            finishEmptySpaceRemoval(success: false)
            return
        }
        if attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.performExplicitSpaceRemoval(displayID: displayID, spaceIndex: spaceIndex, attempt: attempt + 1)
            }
            return
        }
        if let button = missionControlSpaceButton(displayID: displayID, spaceIndex: spaceIndex,
                                                  expectedCount: nil) {
            let result = AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString)
            finishEmptySpaceRemoval(success: result == .success)
            return
        }
        guard attempt < 20 else {
            finishEmptySpaceRemoval(success: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performExplicitSpaceRemoval(displayID: displayID, spaceIndex: spaceIndex, attempt: attempt + 1)
        }
    }

    private func finishEmptySpaceRemoval(success: Bool, completion: (() -> Void)? = nil) {
        if MissionControlDetector.isActive() {
            _ = postNativeKeyShortcut(keyCode: 53, flags: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.isRemovingEmptySpace = false
            self.lastEmptySpaceScanAt = CACurrentMediaTime()
            if success {
                self.lastWindowSignature = ""
                self.scheduleRefresh(after: 0.25)
            }
            completion?()
        }
    }

    /// Mission Control's button for one Space in its Spaces Bar — the element
    /// that carries `AXRemoveDesktop`.
    ///
    /// macOS 27 moved Mission Control's accessibility tree out of the Dock and
    /// into WindowManager, where each `mc.display` group is a direct child of
    /// the application. The Dock still publishes an empty `mc` group, so it is
    /// searched only after WindowManager, for earlier systems.
    ///
    /// `expectedCount` is the display's Space count when the candidate was
    /// chosen; a list of any other length means the indices no longer line up,
    /// and removing by index could take the wrong Deskspace.
    private func missionControlSpaceButton(displayID: CGDirectDisplayID, spaceIndex: Int,
                                           expectedCount: Int?) -> AXUIElement? {
        let hosts = ["com.apple.WindowManager", "com.apple.dock"]
        for bundleID in hosts {
            guard let host = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }) else { continue }
            let root = AXUIElementCreateApplication(host.processIdentifier)
            guard let display = findAXDescendant(in: root, identifier: "mc.display",
                                                 displayID: displayID, depth: 3),
                  let spacesList = findAXDescendant(in: display, identifier: "mc.spaces.list",
                                                    depth: 4) else { continue }
            let children = axChildren(of: spacesList)
            if let expectedCount, children.count != expectedCount { return nil }
            guard children.indices.contains(spaceIndex) else { return nil }
            return children[spaceIndex]
        }
        return nil
    }

    private func findAXDescendant(in element: AXUIElement, identifier: String,
                                  displayID: CGDirectDisplayID? = nil,
                                  depth: Int) -> AXUIElement? {
        if axStringAttribute("AXIdentifier", of: element) == identifier {
            if let displayID {
                if axNumberAttribute("AXDisplayID", of: element)?.uint32Value == displayID {
                    return element
                }
            } else {
                return element
            }
        }
        guard depth > 0 else { return nil }
        for child in axChildren(of: element) {
            if let match = findAXDescendant(in: child, identifier: identifier,
                                            displayID: displayID, depth: depth - 1) {
                return match
            }
        }
        return nil
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private func axStringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axNumberAttribute(_ name: String, of element: AXUIElement) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? NSNumber
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard started, settings.tilingEnabled else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow(forceLayout: false) }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshNow(forceLayout: Bool) {
        guard started, settings.tilingEnabled, PresentationState.shared.canPresent, AXIsProcessTrusted() else {
            controlBar.update([])
            return
        }
        guard !isAnyDisplayAnimating(), !MissionControlDetector.isActive() else {
            refreshDeferred = true
            return
        }
        // Retain explicit commands that arrive during a gesture; the poll after
        // release must apply them even when window geometry has not changed.
        pendingForcedLayout = pendingForcedLayout || forceLayout
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            refreshDeferred = true
            return
        }
        // Do not read an intermediate neighbour frame and start a second
        // layout writer while the first application's queue is still draining.
        if framePipeline.isActive {
            if frameAnimations.isEmpty && !framePipeline.isFinishing {
                if let start = resizeStart { updateLiveNativeResize(start: start) }
                finishFrameWrites()
            }
            refreshDeferred = true
            return
        }
        refreshDeferred = false
        let forceLayout = pendingForcedLayout
        pendingForcedLayout = false
        let spaces = visibleSpaces()
        let windows = visibleWindows()
        finishMouseResize(windows: windows, spaces: spaces)
        if forceLayout { appliedFrames = [:] }
        let registered = registeredWindowIDs()
        let refreshTime = CACurrentMediaTime()
        visibleWindowLastSeenAt = visibleWindowLastSeenAt.filter { registered.contains($0.key) }
        for window in windows { visibleWindowLastSeenAt[window.id] = refreshTime }
        appliedFrames = appliedFrames.filter { registered.contains($0.key) }
        learnedMinimums = learnedMinimums.filter { registered.contains($0.key) }
        shownWindowIDsBySpace = shownWindowIDsBySpace.reduce(into: [:]) { result, entry in
            let live = entry.value.intersection(registered)
            if !live.isEmpty { result[entry.key] = live }
        }
        let focusedID = focusedWindowID()
        var snapshots: [TilingBarSnapshot] = []

        for space in spaces {
            guard !space.isFullscreen else { continue }
            let onDisplay = windows.filter { window in
                guard window.displayUUID.caseInsensitiveCompare(space.key.displayUUID) == .orderedSame else { return false }
                if !window.spaceIDs.isEmpty {
                    return window.spaceIDs.contains(space.key.spaceID)
                }
                return true
            }
            var state = workspaceState(for: space.key)
            let automaticFloatingIDs = Set(onDisplay.filter(\.automaticallyFloating).map(\.id))
            let tiled = reconcile(&state, key: space.key, onDisplay: onDisplay,
                                  registered: registered, focusedID: focusedID)
            let tiledIDs = tiled.map(\.id)

            let treeIDs = state.tree?.windowIDs ?? []
            let tiledIDSet = Set(tiledIDs)
            let orderedMainIDs = treeIDs.filter { state.mainTabIDs.contains($0) }
            let visibleMasterID = TilingLayout.visibleMasterID(
                windowIDs: orderedMainIDs, masterID: state.masterID, visibleIDs: tiledIDSet
            )
            var activeMasterID = visibleMasterID
            var delayForMissingMaster = false
            if let persistedMaster = state.masterID,
               !tiledIDSet.contains(persistedMaster),
               let lastSeen = visibleWindowLastSeenAt[persistedMaster] {
                let elapsed = refreshTime - lastSeen
                if elapsed < 0.75 {
                    delayForMissingMaster = true
                    activeMasterID = persistedMaster
                    scheduleRefresh(after: max(0.05, 0.75 - elapsed))
                }
            }

            if !delayForMissingMaster, !space.isFullscreen, !state.paused,
               (!tiled.isEmpty || forceLayout) {
                applyLayout(to: tiled, state: state, screen: space.screen)
            }
            let commandID = commandWindowID(on: space, windows: windows)
            let visibleStackIDs = treeIDs.filter {
                tiledIDSet.contains($0) && !state.mainTabIDs.contains($0) && $0 != activeMasterID
            }
            let activeStackID = state.stackID.flatMap { visibleStackIDs.contains($0) ? $0 : nil }
                ?? visibleStackIDs.first
            if let activeStackID { state.stackID = activeStackID }
            else if visibleStackIDs.isEmpty { state.stackID = nil }
            states[space.key] = state

            let shownTiledIDs = Set([activeMasterID, activeStackID].compactMap { $0 })
            shownWindowIDsBySpace[space.key] = shownTiledIDs
            let now = CACurrentMediaTime()
            let barWindows = onDisplay.map { window -> TilingBarWindow in
                let app = NSRunningApplication(processIdentifier: window.pid)
                let bundle = app?.bundleIdentifier ?? "pid.\(window.pid)"
                let status: TilingWindowStatus
                if state.floatingIDs.contains(window.id) || window.automaticallyFloating {
                    status = .floating
                } else if state.mode == .masterStack {
                    status = window.id == activeMasterID || state.mainTabIDs.contains(window.id)
                        ? .leftTabbed : .rightTabbed
                } else {
                    status = .split
                }
                return TilingBarWindow(windowID: window.id, pid: window.pid,
                                       bundleID: bundle, name: window.appName,
                                       appName: window.appName, title: window.title,
                                       icon: window.icon, frame: window.frame,
                                       isFocused: window.id == commandID,
                                       isShownInLayout: shownTiledIDs.contains(window.id),
                                       status: status,
                                       floatingIsAutomatic: window.automaticallyFloating,
                                       spaceNumber: space.number,
                                       spaceName: "Desktop \(space.number)")
            }
            for bw in barWindows {
                allBarWindowCache[bw.windowID] = CachedAllBarWindow(
                    window: bw,
                    displayUUID: space.key.displayUUID,
                    lastConfirmedAt: now
                )
            }
            let sortedBarWindows = stableOrderedWindows(
                barWindows,
                displayUUID: space.key.displayUUID,
                spaceNumber: space.number,
                treeIDs: treeIDs
            )
            let barWindowsToUse: [TilingBarWindow]
            if settings.tilingControlBarScope == .allSpaces {
                let pillWindowIDs: Set<CGWindowID>
                if settings.tilingPillScope == .allSpaces {
                    pillWindowIDs = shownWindowIDsBySpace.reduce(into: Set<CGWindowID>()) { result, entry in
                        if entry.key.displayUUID.caseInsensitiveCompare(space.key.displayUUID) == .orderedSame {
                            result.formUnion(entry.value)
                        }
                    }
                } else {
                    pillWindowIDs = shownTiledIDs
                }
                barWindowsToUse = allBarWindows(for: space.key.displayUUID,
                                                currentSpaceID: space.key.spaceID,
                                                currentSpaceNumber: space.number,
                                                focusedID: commandID,
                                                shownWindowIDs: pillWindowIDs)
            } else {
                barWindowsToUse = sortedBarWindows
            }
            // A clicked Desktop that macOS hasn't switched to yet: the bar is
            // already showing it, from `updateControlBarSpaces`. Publishing the
            // Space WindowServer still reports would slide the indicator back
            // to where it came from, then forward again once the switch lands.
            if pendingProgrammaticTarget(for: space.key.displayUUID, current: space.number) != nil {
                continue
            }
            snapshots.append(TilingBarSnapshot(
                displayUUID: space.key.displayUUID,
                spaceNumber: space.number,
                spaceCount: space.total,
                mode: state.mode,
                paused: state.paused,
                windows: barWindowsToUse,
                focusedStatus: TilingLayout.windowStatus(mode: state.mode, paused: state.paused,
                                                         focusedID: commandID, masterID: activeMasterID,
                                                         mainTabIDs: state.mainTabIDs,
                                                         floatingIDs: state.floatingIDs.union(automaticFloatingIDs)),
                focusedIsFloating: commandID.map {
                    state.floatingIDs.contains($0) || automaticFloatingIDs.contains($0)
                } ?? false,
                scope: settings.tilingControlBarScope,
                pillScope: settings.tilingPillScope
            ))
        }
        controlBar.update(snapshots)
        lastWindowSignature = currentWindowSignature()
        updateOverlayDividers()
    }

    /// Brings a Space's tree in line with the windows now on it: windows that
    /// genuinely left drop out, arrivals slot in beside the focused (or last
    /// focused) window. Returns the windows to tile.
    private func reconcile(_ state: inout TilingWorkspaceState, key: TilingSpaceKey,
                           onDisplay: [ManagedTilingWindow], registered: Set<CGWindowID>,
                           focusedID: CGWindowID?) -> [ManagedTilingWindow] {
        state.mode = .masterStack
        // Hidden/minimized windows remain registered. Keep their floating choice.
        state.floatingIDs.formIntersection(registered)

        let floatingIDs = state.floatingIDs
        let tiled = onDisplay.filter {
            !floatingIDs.contains($0.id) && !$0.automaticallyFloating
        }
        let tiledIDs = tiled.map(\.id)
        let oldIDs = Set(state.tree?.windowIDs ?? [])
        let missingIDs = oldIDs.subtracting(tiledIDs)
        let genuinelyRemovedIDs = Set(missingIDs.filter {
            shouldRemoveWindowFromSpace($0, key: key, registered: registered)
        })
        state.tree = state.tree?.removing(ids: genuinelyRemovedIDs)
        state.mainTabIDs.subtract(genuinelyRemovedIDs)
        for window in tiled where !(state.tree?.windowIDs.contains(window.id) ?? false) {
            if let tree = state.tree {
                let targetID = focusedID.flatMap { tree.windowIDs.contains($0) ? $0 : nil }
                    ?? state.lastFocusedID.flatMap { tree.windowIDs.contains($0) ? $0 : nil }
                    ?? tree.windowIDs.last
                let targetFrame = tiled.first(where: { $0.id == targetID })?.frame
                state.tree = tree.inserting(window.id, beside: targetID, targetFrame: targetFrame)
            } else {
                state.tree = .leaf(window.id)
            }
        }
        if let focusedID, onDisplay.contains(where: { $0.id == focusedID }) { state.lastFocusedID = focusedID }
        let treeIDs = state.tree?.windowIDs ?? []
        let treeIDSet = Set(treeIDs)
        state.mainTabIDs.formIntersection(treeIDSet)
        if treeIDs.isEmpty {
            state.columnsInitialized = false
        } else if !state.columnsInitialized, let first = treeIDs.first {
            state.mainTabIDs.insert(first)
            state.columnsInitialized = true
        }
        if state.masterID == nil || !state.mainTabIDs.contains(state.masterID!) {
            state.masterID = treeIDs.first(where: { state.mainTabIDs.contains($0) })
        }
        let stackIDs = treeIDs.filter { !state.mainTabIDs.contains($0) }
        if let focusedID, stackIDs.contains(focusedID) { state.stackID = focusedID }
        if state.stackID == nil || !stackIDs.contains(state.stackID!) { state.stackID = stackIDs.first }
        return tiled
    }

    /// Tiles the destination of a preview-card drop before recapturing the open
    /// Deskspace strip. The destination may be hidden on this display or already
    /// visible on another display; both paths must publish their final geometry
    /// before the preview takes its next snapshot.
    private func layoutSpaceAfterDrop(_ spaceID: Int, attempt: Int = 0) {
        guard started, settings.tilingEnabled, PresentationState.shared.canPresent,
              AXIsProcessTrusted() else { return }
        // Let the Desktop the window left finish retiling first: starting a
        // second layout writer mid-drain makes refreshNow skip its pass.
        if framePipeline.isActive || !frameAnimations.isEmpty || isAnyDisplayAnimating() ||
            MissionControlDetector.isActive() || NSEvent.pressedMouseButtons & 1 != 0 {
            guard attempt < 30 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.layoutSpaceAfterDrop(spaceID, attempt: attempt + 1)
            }
            return
        }

        if visibleSpaces().contains(where: { $0.key.spaceID == spaceID }) {
            refreshNow(forceLayout: true)
            reloadSpacePreviewAfterPendingFrameWrites()
            return
        }

        guard let space = managedSpace(id: spaceID), !space.isFullscreen else {
            reloadSpacePreviewAfterPendingFrameWrites()
            return
        }
        let windows = tileableWindows(onHiddenSpace: space.key)
        var state = workspaceState(for: space.key)
        let tiled = reconcile(&state, key: space.key, onDisplay: windows,
                              registered: registeredWindowIDs(), focusedID: nil)
        states[space.key] = state
        guard !state.paused, !tiled.isEmpty else {
            reloadSpacePreviewAfterPendingFrameWrites()
            return
        }
        // A window can carry an applied-frame record from its source Desktop.
        // A cross-Space drop is an explicit new layout decision, so do not let
        // that stale record suppress the destination's first frame write.
        for window in tiled { appliedFrames.removeValue(forKey: window.id) }
        // Nobody sees these windows move, so skip the spring and write the
        // final frames once.
        applyLayout(to: tiled, state: state, screen: space.screen, animated: false)
        reloadSpacePreviewAfterPendingFrameWrites()
    }

    /// A recapture before the AX frame pipeline settles records the old window
    /// bounds and leaves the strip visually stale. Wait for the final write when
    /// there is one; otherwise refresh immediately (paused/floating/no-op drops).
    private func reloadSpacePreviewAfterPendingFrameWrites() {
        let reload = { [weak self] in
            if #available(macOS 14.0, *) { self?.controlBar.reloadSpacePreview() }
        }
        if framePipeline.isActive || !frameAnimations.isEmpty {
            afterFrameWrites.append(reload)
        } else {
            reload()
        }
    }

    /// Any Desktop by Space id, showing or not.
    private func managedSpace(id spaceID: Int) -> TilingVisibleSpace? {
        guard let raw = TilingCGSCopyManagedDisplaySpaces(TilingCGSMainConnectionID()) as? [[String: Any]] else { return nil }
        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid
        for display in raw {
            let all = display["Spaces"] as? [[String: Any]] ?? []
            // Drops carry `id64`; tiling state is keyed by `ManagedSpaceID`.
            guard let index = all.firstIndex(where: {
                ($0["id64"] as? Int) == spaceID || ($0["ManagedSpaceID"] as? Int) == spaceID
            }) else { continue }
            var uuid = display["Display Identifier"] as? String ?? ""
            if uuid == "Main" { uuid = primaryUUID ?? "" }
            guard !uuid.isEmpty,
                  let screen = NSScreen.screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }),
                  let id = all[index]["ManagedSpaceID"] as? Int ?? all[index]["id64"] as? Int else { return nil }
            return TilingVisibleSpace(key: .init(displayUUID: uuid, spaceID: id), number: index + 1,
                                      total: max(1, all.count), screen: screen,
                                      isFullscreen: (all[index]["type"] as? Int) == 4)
        }
        return nil
    }

    private func applyLayout(to windows: [ManagedTilingWindow], state: TilingWorkspaceState, screen: NSScreen,
                             excluding draggedID: CGWindowID? = nil, animated: Bool = true) {
        guard !windows.isEmpty else { return }
        let gap = max(0, settings.tilingPadding)
        guard let work = workArea(on: screen) else { return }

        let frames: [CGWindowID: CGRect]
        switch state.mode {
        case .splitTree:
            frames = state.tree?.frames(in: work, gap: gap) ?? [:]
        case .masterStack:
            let visibleIDs = Set(windows.map(\.id))
            let orderedVisibleIDs = (state.tree?.windowIDs ?? []).filter { visibleIDs.contains($0) }
            let visibleMainIDs = orderedVisibleIDs.filter { state.mainTabIDs.contains($0) }
            let visibleMasterID = TilingLayout.visibleMasterID(
                windowIDs: visibleMainIDs, masterID: state.masterID, visibleIDs: visibleIDs
            )
            frames = TilingLayout.masterStackFrames(windowIDs: orderedVisibleIDs, masterID: visibleMasterID,
                                                    mainTabIDs: state.mainTabIDs,
                                                    in: work, gap: gap, masterRatio: state.masterRatio,
                                                    minWidths: minWidths(for: orderedVisibleIDs))
        }
        for window in windows where window.id != draggedID {
            guard let target = frames[window.id], !approximatelyEqual(window.frame, target) else { continue }
            if let animation = frameAnimations[window.id], approximatelyEqual(animation.target, target) {
                continue
            }
            // Some apps enforce a minimum size. Do not keep sending the same
            // rejected rectangle whenever focus changes or the poll timer fires.
            // Only a window left *larger* than asked is refusing; `actual` is
            // the frame before the write, so a write that was merely lost (the
            // neighbour quitting mid-animation) also matches it — skipping that
            // stranded a lone window at its old half width for good.
            if let previous = appliedFrames[window.id],
               approximatelyEqual(previous.target, target), approximatelyEqual(previous.actual, window.frame),
               window.frame.width > target.width + 2 || window.frame.height > target.height + 2 { continue }
            if animated {
                animateFrame(from: window.frame, to: target, windowID: window.id, element: window.element)
            } else {
                enqueueFrame(target, id: window.id, element: window.element)
            }
            appliedFrames[window.id] = (target, window.frame)
        }
        if !animated { stopFrameAnimationTimerIfIdle() }
    }

    private func workArea(on screen: NSScreen) -> CGRect? {
        let gap = max(0, settings.tilingPadding)
        let barHeight = settings.tilingShowControlBar ? TilingControlBarController.barHeight(for: screen) : 0
        var work = screen.visibleFrame
        let reservedTop = screen.frame.maxY - barHeight
        if work.maxY > reservedTop { work.size.height -= work.maxY - reservedTop }
        work = work.insetBy(dx: gap, dy: gap)
        return work.width > 80 && work.height > 80 ? work : nil
    }

    private func beginMouseResize() {
        guard handleDragSession == nil else { return }
        cancelFrameAnimations()
        resizeOverlay.showDropPreview(frame: nil)
        resizeOverlay.hideResizePreviews()
        resizeStart = nil
        dropPoint = nil
        gestureHasResized = false
        dragStartPoint = nil
        dragStartedOnResizeEdge = false
        dragStartedInTitleBar = false
        guard PresentationState.shared.canPresent else { return }
        let point = NSEvent.mouseLocation
        let windows = recentVisibleWindows()
        let spaces = visibleSpaces()
        guard let window = windows.first(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }),
              let space = spaces.first(where: { $0.key.displayUUID == window.displayUUID && !$0.isFullscreen &&
                  (window.spaceIDs.isEmpty || window.spaceIDs.contains($0.key.spaceID)) }),
              let state = states[space.key], !state.paused,
              // A floating window is dragged and resized on its own terms: no
              // drop tile, no neighbour resizing, nothing tiling to show.
              !state.floatingIDs.contains(window.id), !window.automaticallyFloating,
              state.tree?.windowIDs.contains(window.id) == true,
              let work = workArea(on: space.screen) else { return }
        let neighbors = windows.filter {
            $0.displayUUID == space.key.displayUUID &&
                !state.floatingIDs.contains($0.id) && !$0.automaticallyFloating && $0.id != window.id
        }.map { ($0.id, $0.element) }
        dragStartPoint = point
        dragStartedOnResizeEdge = !window.frame.insetBy(dx: 6, dy: 6).contains(point)
        dragStartedInTitleBar = !dragStartedOnResizeEdge && point.y >= window.frame.maxY - Self.titleBarDragHeight
        resizeStart = (window.id, window.frame, space.key, work, state, space, window.element, neighbors)
    }

    private func finishMouseResize(windows: [ManagedTilingWindow], spaces: [TilingVisibleSpace]) {
        updateMouseResize(windows: windows, spaces: spaces, live: false)
        resizeStart = nil
        dragStartPoint = nil
    }

    /// Commit the mouse gesture before the next AX/WindowServer scan. Some apps
    /// restore or resize their window as soon as mouse-up is delivered, so their
    /// post-drop frame cannot reliably tell us where the user released it.
    @discardableResult
    private func commitColumnDropFromGesture() -> Bool {
        guard let start = resizeStart, start.state.mode == .masterStack,
              !gestureHasResized, !dragStartedOnResizeEdge,
              let dropPoint, let dragStartPoint = windowDragStartPoint,
              let tree = start.state.tree,
              var state = states[start.key], !state.paused,
              state.mode == .masterStack,
              state.tree?.windowIDs == tree.windowIDs,
              workArea(on: start.space.screen) == start.work else { return false }

        let slots = TilingLayout.masterStackFrames(
            windowIDs: tree.windowIDs, masterID: state.masterID,
            mainTabIDs: state.mainTabIDs, in: start.work,
            gap: max(0, settings.tilingPadding), masterRatio: state.masterRatio)
        guard let placement = TilingLayout.columnDropPlacement(
            movingID: start.id, from: start.frame, to: start.frame,
            pointer: dropPoint, dragStart: dragStartPoint, slots: slots,
            leftIDs: state.mainTabIDs, leftActiveID: state.masterID,
            rightActiveID: state.stackID, splitRatio: state.masterRatio) else { return false }

        let columns: TilingColumnAssignment?
        switch placement.kind {
        case .tab:
            columns = TilingLayout.movingTab(
                start.id, onto: placement.targetID, orderedIDs: tree.windowIDs,
                leftIDs: state.mainTabIDs, leftActiveID: state.masterID,
                rightActiveID: state.stackID)
        case .swap:
            columns = TilingLayout.swappingTabs(
                start.id, with: placement.targetID, leftIDs: state.mainTabIDs)
        case .split(let toLeft):
            columns = TilingLayout.splittingColumn(
                start.id, toLeft: toLeft, orderedIDs: tree.windowIDs,
                leftActiveID: state.masterID, rightActiveID: state.stackID)
        }
        guard let columns else { return false }
        state.mainTabIDs = columns.leftIDs
        state.masterID = columns.leftActiveID
        state.stackID = columns.rightActiveID
        state.columnsInitialized = true
        states[start.key] = state
        appliedFrames = [:]
        return true
    }

    private func scheduleLiveResize() {
        guard handleDragSession == nil else { return }
        guard resizeStart != nil, resizeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeWork = nil
            guard self.started, self.settings.tilingEnabled, PresentationState.shared.canPresent,
                  NSEvent.pressedMouseButtons & 1 != 0,
                  let start = self.resizeStart else { return }
            self.updateLiveNativeResize(start: start)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TilingDisplayClock.interval(for: resizeStart?.space.screen), execute: work)
    }

    private func updateLiveNativeResize(start: (
        id: CGWindowID,
        frame: CGRect,
        key: TilingSpaceKey,
        work: CGRect,
        state: TilingWorkspaceState,
        space: TilingVisibleSpace,
        draggedElement: AXUIElement,
        neighbors: [(id: CGWindowID, element: AXUIElement)]
    )) {
        let currentFrame = WindowPreviewCapture.axFrame(of: start.draggedElement)
            .map(axToAppKit) ?? start.frame
        let gap = max(0, settings.tilingPadding)
        guard let tree = start.state.tree else { return }
        let sizeChanged = abs(currentFrame.width - start.frame.width) > 2 || abs(currentFrame.height - start.frame.height) > 2
        let isResize = sizeChanged && (start.state.mode != .masterStack || dragStartedOnResizeEdge)
        gestureHasResized = gestureHasResized || isResize
        if !gestureHasResized {
            let pointer = NSEvent.mouseLocation
            let windowMoved = abs(currentFrame.minX - start.frame.minX) > 8 ||
                abs(currentFrame.minY - start.frame.minY) > 8
            let hasMoved = windowMoved || (windowDragStartPoint.map {
                hypot(pointer.x - $0.x, pointer.y - $0.y) > 8
            } ?? false)
            let slots = start.state.mode == .splitTree
                ? tree.frames(in: start.work, gap: gap)
                : TilingLayout.masterStackFrames(windowIDs: tree.windowIDs,
                                                 masterID: start.state.masterID,
                                                 mainTabIDs: start.state.mainTabIDs,
                                                 in: start.work, gap: gap,
                                                 masterRatio: start.state.masterRatio)
            var previewFrame: CGRect?
            var previewKind: TilingDropPreviewKind = .move
            if !hasMoved {
                previewFrame = nil
            } else if start.state.mode == .masterStack {
                let placement = TilingLayout.columnDropPlacement(
                    movingID: start.id, from: start.frame, to: currentFrame,
                    pointer: pointer, dragStart: windowDragStartPoint, slots: slots,
                    leftIDs: start.state.mainTabIDs,
                    leftActiveID: start.state.masterID,
                    rightActiveID: start.state.stackID,
                    splitRatio: start.state.masterRatio
                )
                previewFrame = placement?.previewFrame
                switch placement?.kind {
                case .swap: previewKind = .swap
                case .tab: previewKind = .tab
                case .split(let left): previewKind = .split(left: left)
                case nil: previewKind = .move
                }
            } else {
                previewFrame = TilingLayout.dropTarget(
                    movingID: start.id, from: start.frame, to: currentFrame,
                    pointer: NSEvent.mouseLocation, slots: slots
                ).flatMap { slots[$0] }
            }
            resizeOverlay.showDropPreview(frame: previewFrame, kind: previewKind)
        } else {
            resizeOverlay.showDropPreview(frame: nil)
        }
        guard gestureHasResized, var state = states[start.key], !state.paused else { return }

        switch state.mode {
        case .splitTree:
            state.tree = tree.resized(windowID: start.id, from: start.frame, to: currentFrame, in: start.work, gap: gap)
        case .masterStack:
            state.masterRatio = start.state.masterRatio
            if abs(currentFrame.width - start.frame.width) > 2 {
                let delta = state.mainTabIDs.contains(start.id)
                    ? currentFrame.maxX - start.frame.maxX : currentFrame.minX - start.frame.minX
                state.masterRatio = min(0.8, max(0.2, start.state.masterRatio + delta / max(1, start.work.width - gap)))
            }
        }
        states[start.key] = state

        let frames: [CGWindowID: CGRect]
        switch state.mode {
        case .splitTree:
            frames = state.tree?.frames(in: start.work, gap: gap) ?? [:]
        case .masterStack:
            frames = TilingLayout.masterStackFrames(windowIDs: state.tree?.windowIDs ?? [], masterID: state.masterID,
                                                    mainTabIDs: state.mainTabIDs,
                                                    in: start.work, gap: gap, masterRatio: state.masterRatio)
        }
        if settings.tilingStablePreviewResize {
            let previewFrames = Dictionary(uniqueKeysWithValues: start.neighbors.compactMap { neighbor in
                frames[neighbor.id].map { (neighbor.id, $0) }
            })
            resizeOverlay.showResizePreviews(frames: previewFrames)
        } else {
            resizeOverlay.hideResizePreviews()
            for neighbor in start.neighbors {
                guard let target = frames[neighbor.id] else { continue }
                enqueueFrame(target, id: neighbor.id, element: neighbor.element)
            }
        }
    }

    private func updateMouseResize(windows: [ManagedTilingWindow], spaces: [TilingVisibleSpace], live: Bool) {
        guard let start = resizeStart,
              let space = spaces.first(where: { $0.key == start.key && !$0.isFullscreen }),
              workArea(on: space.screen) == start.work,
              let window = windows.first(where: { $0.id == start.id && $0.displayUUID == start.key.displayUUID }),
              let tree = start.state.tree,
              states[start.key]?.mode == start.state.mode,
              Set(tree.windowIDs) == Set(windows.filter { $0.displayUUID == start.key.displayUUID &&
                  ($0.spaceIDs.isEmpty || $0.spaceIDs.contains(start.key.spaceID)) &&
                  !(states[start.key]?.floatingIDs.contains($0.id) ?? false) && !$0.automaticallyFloating }.map(\.id)),
              var state = states[start.key], !state.paused else { return }
        let gap = max(0, settings.tilingPadding)
        let sizeChanged = abs(window.frame.width - start.frame.width) > 2 || abs(window.frame.height - start.frame.height) > 2
        let isResize = sizeChanged && (start.state.mode != .masterStack || dragStartedOnResizeEdge)
        gestureHasResized = gestureHasResized || isResize
        if !gestureHasResized {
            guard !live, let dropPoint else { return }
            let slots = start.state.mode == .splitTree
                ? tree.frames(in: start.work, gap: gap)
                : TilingLayout.masterStackFrames(windowIDs: tree.windowIDs, masterID: start.state.masterID,
                                                 mainTabIDs: start.state.mainTabIDs,
                                                 in: start.work, gap: gap, masterRatio: start.state.masterRatio)
            if start.state.mode == .masterStack,
               let placement = TilingLayout.columnDropPlacement(
                    movingID: start.id, from: start.frame, to: window.frame,
                    pointer: dropPoint, dragStart: windowDragStartPoint, slots: slots,
                    leftIDs: state.mainTabIDs,
                    leftActiveID: state.masterID,
                    rightActiveID: state.stackID
               ) {
                let columns: TilingColumnAssignment?
                switch placement.kind {
                case .tab:
                    columns = TilingLayout.movingTab(
                        start.id, onto: placement.targetID, orderedIDs: tree.windowIDs,
                        leftIDs: state.mainTabIDs, leftActiveID: state.masterID,
                        rightActiveID: state.stackID
                    )
                case .swap:
                    columns = TilingLayout.swappingTabs(
                        start.id, with: placement.targetID, leftIDs: state.mainTabIDs
                    )
                case .split(let toLeft):
                    columns = TilingLayout.splittingColumn(
                        start.id, toLeft: toLeft, orderedIDs: tree.windowIDs,
                        leftActiveID: state.masterID, rightActiveID: state.stackID
                    )
                }
                if let columns {
                    state.mainTabIDs = columns.leftIDs
                    state.masterID = columns.leftActiveID
                    state.stackID = columns.rightActiveID
                    state.columnsInitialized = true
                }
                states[start.key] = state
                appliedFrames = [:]
            } else if start.state.mode == .splitTree,
                      let target = TilingLayout.dropTarget(
                        movingID: start.id, from: start.frame, to: window.frame,
                        pointer: dropPoint, slots: slots
                      ) {
                state.tree = tree.swapping(start.id, with: target)
                states[start.key] = state
                appliedFrames = [:]
            }
            return
        }
        switch state.mode {
        case .splitTree:
            state.tree = tree.resized(windowID: start.id, from: start.frame, to: window.frame, in: start.work, gap: gap)
        case .masterStack:
            state.masterRatio = start.state.masterRatio
            if abs(window.frame.width - start.frame.width) > 2 {
                let delta = state.mainTabIDs.contains(start.id)
                    ? window.frame.maxX - start.frame.maxX : window.frame.minX - start.frame.minX
                state.masterRatio = min(0.8, max(0.2, start.state.masterRatio + delta / max(1, start.work.width - gap)))
            }
        }
        states[start.key] = state
        settings.setTilingMasterRatio(state.masterRatio, for: start.key.displayUUID)
        appliedFrames = [:]
    }

    private func handleOverlayResizeStart(divider: TilingDivider) {
        cancelFrameAnimations()
        overlayResizeWork?.cancel()
        overlayResizeWork = nil
        pendingOverlayResize = nil
        resizeOverlay.showDropPreview(frame: nil)
        resizeOverlay.hideResizePreviews()
        resizeStart = nil
        resizeWork?.cancel()
        resizeWork = nil
        let point = NSEvent.mouseLocation
        let spaces = visibleSpaces()
        let matchingSpace = spaces.first(where: { space in
            guard !space.isFullscreen, let work = workArea(on: space.screen) else { return false }
            return work.intersects(divider.parentRect)
        }) ?? spaces.first(where: { space in
            !space.isFullscreen && space.screen.frame.contains(point)
        })
        guard let space = matchingSpace,
              let work = workArea(on: space.screen),
              let state = states[space.key], !state.paused else { return }

        let windows = visibleWindows().filter {
            $0.displayUUID == space.key.displayUUID && !state.floatingIDs.contains($0.id) && !$0.automaticallyFloating
        }
        var cached: [CGWindowID: AXUIElement] = [:]
        for w in windows { cached[w.id] = w.element }

        let gap = max(0, settings.tilingPadding)
        handleDragSession = ActiveHandleDragSession(
            spaceKey: space.key,
            screen: space.screen,
            work: work,
            gap: gap,
            cachedElements: cached,
            currentState: state,
            minSizes: minimumSizes(for: cached)
        )
    }

    /// Mouse drag events can arrive much faster than Accessibility can resize
    /// several app windows. Keep only the newest coordinate and apply it once
    /// per display frame so old resize requests never build up behind the cursor.
    private func scheduleOverlayResize(divider: TilingDivider, coordinate: CGFloat) {
        pendingOverlayResize = (divider, coordinate)
        guard overlayResizeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.overlayResizeWork = nil
            guard let pending = self.pendingOverlayResize else { return }
            self.pendingOverlayResize = nil
            self.handleOverlayResizeDrag(divider: pending.divider, coordinate: pending.coordinate)
        }
        overlayResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TilingDisplayClock.interval(for: handleDragSession?.screen), execute: work)
    }

    private func flushOverlayResize() {
        overlayResizeWork?.cancel()
        overlayResizeWork = nil
        guard let pending = pendingOverlayResize else { return }
        pendingOverlayResize = nil
        handleOverlayResizeDrag(divider: pending.divider, coordinate: pending.coordinate)
    }

    private func handleOverlayResizeDrag(divider: TilingDivider, coordinate: CGFloat) {
        guard var session = handleDragSession else { return }

        func clampCoord(_ coord: CGFloat, minSizes: [CGWindowID: CGSize]) -> CGFloat {
            var safe = coord
            if divider.axis == .vertical {
                let available = max(1, divider.parentRect.width - session.gap)
                let baseMinW = min(200.0, floor(available * 0.45))
                let firstMinW = (divider.firstWindowIDs.compactMap { minSizes[$0]?.width } + [baseMinW]).max() ?? baseMinW
                let secondMinW = (divider.secondWindowIDs.compactMap { minSizes[$0]?.width } + [baseMinW]).max() ?? baseMinW
                let minAllowed = divider.parentRect.minX + firstMinW + session.gap / 2.0
                let maxAllowed = divider.parentRect.maxX - secondMinW - session.gap / 2.0
                if minAllowed <= maxAllowed {
                    safe = min(maxAllowed, max(minAllowed, safe))
                }
            } else {
                let available = max(1, divider.parentRect.height - session.gap)
                let baseMinH = min(140.0, floor(available * 0.45))
                let firstMinH = (divider.firstWindowIDs.compactMap { minSizes[$0]?.height } + [baseMinH]).max() ?? baseMinH
                let secondMinH = (divider.secondWindowIDs.compactMap { minSizes[$0]?.height } + [baseMinH]).max() ?? baseMinH
                let minAllowed = divider.parentRect.minY + secondMinH + session.gap / 2.0
                let maxAllowed = divider.parentRect.maxY - firstMinH - session.gap / 2.0
                if minAllowed <= maxAllowed {
                    safe = min(maxAllowed, max(minAllowed, safe))
                }
            }
            return safe
        }

        let safeCoord = clampCoord(coordinate, minSizes: session.minSizes)
        let newRatio = TilingLayout.ratio(for: divider, at: safeCoord, gap: session.gap)

        if divider.isMasterDivider {
            session.currentState.masterRatio = newRatio
        } else if let path = divider.treePath {
            session.currentState.tree = session.currentState.tree?.updatingRatio(at: path, to: newRatio)
        }
        handleDragSession?.currentState = session.currentState

        let frames: [CGWindowID: CGRect]
        switch session.currentState.mode {
        case .splitTree:
            frames = session.currentState.tree?.frames(in: session.work, gap: session.gap) ?? [:]
        case .masterStack:
            frames = TilingLayout.masterStackFrames(windowIDs: session.currentState.tree?.windowIDs ?? [],
                                                    masterID: session.currentState.masterID,
                                                    mainTabIDs: session.currentState.mainTabIDs,
                                                    in: session.work, gap: session.gap,
                                                    masterRatio: session.currentState.masterRatio)
        }
        let affected = Set(divider.firstWindowIDs + divider.secondWindowIDs)
        if settings.tilingStablePreviewResize {
            resizeOverlay.showResizePreviews(frames: frames.filter { affected.contains($0.key) })
        } else {
            resizeOverlay.hideResizePreviews()
            for id in affected {
                guard let target = frames[id], let element = session.cachedElements[id] else { continue }
                // AX success does not mean the application has presented this
                // frame. A readback can still contain the preceding, larger
                // size; treating that as a minimum makes the divider jump back.
                enqueueFrame(target, id: id, element: element)
            }
        }

        resizeOverlay.updateHandlePosition(dividerID: divider.id, coordinate: safeCoord)
    }

    private func handleOverlayResizeEnd() {
        guard let session = handleDragSession else { return }
        states[session.spaceKey] = session.currentState
        settings.setTilingMasterRatio(session.currentState.masterRatio,
                                      for: session.spaceKey.displayUUID)
        handleDragSession = nil
        resizeOverlay.hideResizePreviews()
        appliedFrames = [:]
        updateOverlayDividers()
        finishFrameWrites()
        refreshNow(forceLayout: false)
    }

    private func updateOverlayDividers() {
        guard started, settings.tilingEnabled, PresentationState.shared.canPresent, !MissionControlDetector.isActive() else {
            resizeOverlay.update(dividers: [:])
            return
        }
        let spaces = visibleSpaces()
        let gap = max(0, settings.tilingPadding)
        var divsByDisplay: [String: [TilingDivider]] = [:]
        var tiledIDs: Set<CGWindowID> = []
        for space in spaces {
            guard !space.isFullscreen, let state = states[space.key], !state.paused,
                  let work = workArea(on: space.screen) else { continue }
            // The tree keeps floating, hidden and minimized windows; only the
            // ones actually drawn in the layout have an edge to drag. A single
            // tile fills the work area, so its "divider" is nothing but a
            // handle floating over whatever sits on top of it.
            let shown = shownWindowIDsBySpace[space.key] ?? []
            tiledIDs.formUnion(shown)
            guard shown.count >= 2 else { continue }
            let divs = TilingLayout.dividers(mode: state.mode, tree: state.tree,
                                             masterID: state.masterID, mainTabIDs: state.mainTabIDs,
                                             masterRatio: state.masterRatio,
                                             in: work, gap: gap,
                                             minWidths: minWidths(for: state.tree?.windowIDs ?? []))
            divsByDisplay[space.key.displayUUID] = divs
        }
        resizeOverlay.update(dividers: divsByDisplay, tiledWindowIDs: tiledIDs)
    }

    private func registeredWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return Set(states.values.flatMap { $0.floatingIDs })
        }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    private func shouldRemoveWindowFromSpace(_ windowID: CGWindowID, key: TilingSpaceKey,
                                             registered: Set<CGWindowID>) -> Bool {
        guard registered.contains(windowID) else { return true }
        let memberships = (TilingCGSCopySpacesForWindows(
            TilingCGSMainConnectionID(), 7, [windowID] as CFArray
        ) as? [Int]) ?? []
        // Empty membership is transient during Space/window animations. Keep
        // the existing tree slot so Main and Tab windows cannot exchange sides.
        guard !memberships.isEmpty else { return false }
        return !memberships.contains(key.spaceID)
    }

    /// A window that came back wider or taller than it was asked to be has told
    /// us its floor. Only refusals count: a window that accepted its frame says
    /// nothing about how far it would have gone.
    private func learnMinimum(id: CGWindowID, target: CGRect, actual: CGRect) {
        var minimum = learnedMinimums[id] ?? .zero
        if actual.width > target.width + 2 { minimum.width = max(minimum.width, actual.width) }
        if actual.height > target.height + 2 { minimum.height = max(minimum.height, actual.height) }
        guard minimum != .zero else { return }
        learnedMinimums[id] = minimum
    }

    /// Learned minimum widths for a set of windows, for the layout math.
    private func minWidths(for ids: [CGWindowID]) -> [CGWindowID: CGFloat] {
        ids.reduce(into: [CGWindowID: CGFloat]()) { result, id in
            if let width = learnedMinimums[id]?.width, width > 0 { result[id] = width }
        }
    }

    /// Declared minimums where an app publishes them, learned ones otherwise.
    private func minimumSizes(for windows: [CGWindowID: AXUIElement]) -> [CGWindowID: CGSize] {
        windows.reduce(into: [CGWindowID: CGSize]()) { result, entry in
            let declared = declaredMinimumSize(of: entry.value) ?? .zero
            let learned = learnedMinimums[entry.key] ?? .zero
            let combined = CGSize(width: max(declared.width, learned.width),
                                  height: max(declared.height, learned.height))
            if combined != .zero { result[entry.key] = combined }
        }
    }

    private func declaredMinimumSize(of window: AXUIElement) -> CGSize? {
        for attribute in ["AXMinSize", "AXMinimumSize"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { continue }
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cgSize else { continue }
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size),
                  size.width.isFinite, size.height.isFinite,
                  size.width >= 0, size.height >= 0 else { continue }
            return size
        }
        return nil
    }

    private func enqueueFrame(_ appKitFrame: CGRect, id: CGWindowID, element: AXUIElement) {
        let bounds = handleDragSession?.work ?? resizeStart?.work ??
            NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame) }).flatMap { workArea(on: $0) }
        var target = appKitFrame
        if let bounds {
            target.origin.x = max(bounds.minX, min(target.minX, bounds.maxX - target.width))
            target.origin.y = max(bounds.minY, min(target.minY, bounds.maxY - target.height))
        }
        if let previous = pendingFrameTargets[id], approximatelyEqual(previous, target) { return }
        pendingFrameTargets[id] = target
        framePipeline.submit(id: id, element: element, frame: appKitToAX(target))
    }

    private func finishFrameWrites() {
        guard !framePipeline.isFinishing, framePipeline.isActive else { return }
        let targets = pendingFrameTargets
        pendingFrameTargets.removeAll()
        framePipeline.finish { [weak self] observed in
            guard let self else { return }
            for (id, actualAX) in observed {
                guard let target = targets[id] else { continue }
                let actual = self.axToAppKit(actualAX)
                self.appliedFrames[id] = (target, actual)
                self.learnMinimum(id: id, target: target, actual: actual)
            }
            let followUps = self.afterFrameWrites
            self.afterFrameWrites.removeAll()
            followUps.forEach { $0() }
            self.scheduleRefresh(after: 0.01)
        }
    }

    /// Animates both origin and size after a tiling decision. Live mouse and
    /// divider resizing stay attached to the pointer; release, swap, re-tile and
    /// reposition settle through this same interruptible spring.
    private func animateFrame(from fallbackStart: CGRect, to target: CGRect,
                              windowID: CGWindowID, element: AXUIElement) {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = frameAnimations.removeValue(forKey: windowID)
        let inherited = previous.map { animation in
            TilingLayout.springFrame(
                from: animation.start, to: animation.target,
                initialVelocity: animation.initialVelocity,
                elapsed: now - animation.startedAt,
                response: Self.frameSpringResponse
            )
        }
        let start = inherited?.frame ?? fallbackStart
        let initialVelocity = inherited?.velocity ?? .zero
        guard let screen = NSScreen.screens.max(by: {
            let a = $0.frame.intersection(target), b = $1.frame.intersection(target)
            return a.width * a.height < b.width * b.height
        }), let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !approximatelyEqual(start, target) else {
            enqueueFrame(target, id: windowID, element: element)
            stopFrameAnimationTimerIfIdle()
            return
        }

        frameAnimations[windowID] = ActiveFrameAnimation(
            element: element,
            displayID: displayID,
            start: start,
            target: target,
            initialVelocity: initialVelocity,
            startedAt: now,
            duration: Self.frameSpringDuration
        )
        startFrameAnimationClockIfNeeded(screen: screen, displayID: displayID)
    }

    private func startFrameAnimationClockIfNeeded(screen: NSScreen, displayID: CGDirectDisplayID) {
        guard frameAnimationClocks[displayID] == nil else { return }
        frameAnimationClocks[displayID] = TilingDisplayClock(screen: screen) { [weak self] in
            self?.advanceFrameAnimations(on: displayID)
        }
    }

    private func advanceFrameAnimations(on displayID: CGDirectDisplayID) {
        let now = ProcessInfo.processInfo.systemUptime
        var completed: [CGWindowID] = []
        for (id, animation) in frameAnimations where animation.displayID == displayID {
            let elapsed = max(0, now - animation.startedAt)
            let sample = TilingLayout.springFrame(
                from: animation.start, to: animation.target,
                initialVelocity: animation.initialVelocity,
                elapsed: elapsed,
                response: Self.frameSpringResponse
            )
            enqueueFrame(sample.frame, id: id, element: animation.element)
            if elapsed >= animation.duration { completed.append(id) }
        }

        for id in completed {
            guard let animation = frameAnimations.removeValue(forKey: id) else { continue }
            enqueueFrame(animation.target, id: id, element: animation.element)
        }
        stopFrameAnimationTimerIfIdle()
    }

    private func stopFrameAnimationTimerIfIdle() {
        let activeDisplays = Set(frameAnimations.values.map(\.displayID))
        for id in Array(frameAnimationClocks.keys) where !activeDisplays.contains(id) {
            frameAnimationClocks.removeValue(forKey: id)?.invalidate()
        }
        guard frameAnimations.isEmpty else { return }
        // Defer until all windows in this layout pass have been submitted.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frameAnimations.isEmpty,
                  self.resizeStart == nil, self.handleDragSession == nil else { return }
            self.finishFrameWrites()
        }
    }

    private func cancelFrameAnimations() {
        framePipeline.cancel()
        pendingFrameTargets.removeAll()
        afterFrameWrites.removeAll()
        frameAnimations.removeAll()
        frameAnimationClocks.values.forEach { $0.invalidate() }
        frameAnimationClocks.removeAll()
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1 &&
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    private func stableOrderedWindows(
        _ windows: [TilingBarWindow],
        displayUUID: String,
        spaceNumber: Int,
        treeIDs: [CGWindowID] = []
    ) -> [TilingBarWindow] {
        let key = "\(displayUUID.lowercased())_\(spaceNumber)"
        var cachedOrder = orderedWindowIDsBySpace[key] ?? []
        let currentIDs = Set(windows.map(\.windowID))

        // Genuinely closed windows are purged from the cached order
        cachedOrder.removeAll { !currentIDs.contains($0) }

        let windowMap = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        // Known windows preserve their exact relative order
        var orderedWindows: [TilingBarWindow] = []
        for wid in cachedOrder {
            if let win = windowMap[wid] {
                orderedWindows.append(win)
            }
        }

        // New windows not yet in cached order
        let existingIDs = Set(orderedWindows.map(\.windowID))
        let newWindows = windows.filter { !existingIDs.contains($0.windowID) }

        if !newWindows.isEmpty {
            // Sort new windows predictably: by category priority, tree order, then position
            let sortedNew = newWindows.sorted { w1, w2 in
                let cat1 = Self.categoryPriority(w1.status)
                let cat2 = Self.categoryPriority(w2.status)
                if cat1 != cat2 { return cat1 < cat2 }
                if let idx1 = treeIDs.firstIndex(of: w1.windowID),
                   let idx2 = treeIDs.firstIndex(of: w2.windowID) {
                    return idx1 < idx2
                }
                if abs(w1.frame.minX - w2.frame.minX) > 12 {
                    return w1.frame.minX < w2.frame.minX
                }
                if abs(w1.frame.maxY - w2.frame.maxY) > 12 {
                    return w1.frame.maxY > w2.frame.maxY
                }
                return w1.bundleID < w2.bundleID
            }

            // Insert new windows into their category section predictably
            for newWin in sortedNew {
                let newCat = Self.categoryPriority(newWin.status)
                if let insertIdx = orderedWindows.firstIndex(where: { Self.categoryPriority($0.status) > newCat }) {
                    orderedWindows.insert(newWin, at: insertIdx)
                } else {
                    orderedWindows.append(newWin)
                }
            }
        }

        // Re-group every tab, not just the first left window. Cached order is
        // still preserved within each column when tabs move between sides.
        orderedWindows = TilingWindowStatus.groupedForColumns(orderedWindows) { $0.status }

        // Persist the stable order
        orderedWindowIDsBySpace[key] = orderedWindows.map(\.windowID)
        return orderedWindows
    }

    /// Every window on this display, across Spaces, for the bar's All Spaces
    /// scope. Rebuilding it asks every running app for its windows over
    /// Accessibility — the most expensive thing on the refresh path, and a
    /// refresh runs on every click. The answer only changes when a window
    /// opens or closes, or when what the bar marks changes, so it is kept
    /// until then, and in any case no longer than `allBarWindowsMaxAge`.
    private func allBarWindows(for displayUUID: String, currentSpaceID: Int,
                               currentSpaceNumber: Int, focusedID: CGWindowID?,
                               shownWindowIDs: Set<CGWindowID>) -> [TilingBarWindow] {
        let registeredIDs = registeredWindowIDs()
        let key = [
            registeredIDs.sorted().map(String.init).joined(separator: ","),
            String(currentSpaceID), String(currentSpaceNumber), String(focusedID ?? 0),
            shownWindowIDs.sorted().map(String.init).joined(separator: ",")
        ].joined(separator: "|")
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = allBarWindowsCache[displayUUID], cached.key == key,
           now - cached.stamp < Self.allBarWindowsMaxAge {
            return cached.windows
        }
        let windows = computeAllBarWindows(for: displayUUID, currentSpaceID: currentSpaceID,
                                           currentSpaceNumber: currentSpaceNumber, focusedID: focusedID,
                                           shownWindowIDs: shownWindowIDs, registeredIDs: registeredIDs)
        allBarWindowsCache[displayUUID] = (stamp: now, key: key, windows: windows)
        return windows
    }

    private func computeAllBarWindows(for displayUUID: String, currentSpaceID: Int,
                                      currentSpaceNumber: Int, focusedID: CGWindowID?,
                                      shownWindowIDs: Set<CGWindowID>,
                                      registeredIDs: Set<CGWindowID>) -> [TilingBarWindow] {
        let cid = TilingCGSMainConnectionID()
        guard let rawDisplays = TilingCGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid

        var targetDisplay: [String: Any]? = nil
        for d in rawDisplays {
            var uuid = d["Display Identifier"] as? String ?? ""
            if uuid == "Main" { uuid = primaryUUID ?? "" }
            if uuid.caseInsensitiveCompare(displayUUID) == .orderedSame {
                targetDisplay = d
                break
            }
        }
        guard let targetDisplay else { return [] }

        let rawSpaces = targetDisplay["Spaces"] as? [[String: Any]] ?? []
        var spaceIndexMap: [Int: Int] = [:]
        for (i, s) in rawSpaces.enumerated() {
            let sid = s["ManagedSpaceID"] as? Int ?? s["id64"] as? Int ?? 0
            if sid > 0 {
                spaceIndexMap[sid] = i + 1
            }
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [TilingBarWindow] = []
        var seenPerSpace = Set<String>()

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != myPID
        }
        let runningPIDs = Set(runningApps.map(\.processIdentifier))
        allBarWindowCache = allBarWindowCache.filter {
            registeredIDs.contains($0.key) && runningPIDs.contains($0.value.window.pid)
        }
        let now = CACurrentMediaTime()

        for app in runningApps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "App"
            let bundle = app.bundleIdentifier ?? "pid.\(pid)"
            let icon = app.icon

            let switcherWins = WindowPreviewCapture.switcherWindows(pid: pid, scriptBrowsers: false).sorted {
                shownWindowIDs.contains($0.id) && !shownWindowIDs.contains($1.id)
            }
            for win in switcherWins where win.id != 0 {
                let frame = axToAppKit(win.bounds)
                let cachedOwner = allBarWindowCache[win.id]?.displayUUID
                let resolvedDisplayUUID = screen(containing: frame)?.uuid ?? cachedOwner
                guard let resolvedDisplayUUID,
                      resolvedDisplayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame else {
                    // Do not let a transient empty Space membership copy an
                    // on-screen window into every display's control bar.
                    if cachedOwner?.caseInsensitiveCompare(displayUUID) == .orderedSame {
                        allBarWindowCache.removeValue(forKey: win.id)
                    }
                    continue
                }
                var wSpaces = (TilingCGSCopySpacesForWindows(cid, 7, [win.id] as CFArray) as? [Int]) ?? []
                if wSpaces.isEmpty {
                    if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], win.id) as? [[String: Any]],
                       !onScreen.isEmpty {
                        wSpaces = [currentSpaceID]
                    }
                }
                var targetSpaceNum: Int? = nil
                if wSpaces.contains(currentSpaceID) {
                    targetSpaceNum = currentSpaceNumber
                } else {
                    for sid in wSpaces {
                        if let sNum = spaceIndexMap[sid] {
                            targetSpaceNum = sNum
                            break
                        }
                    }
                }
                // Fall back to cached space number if CGS query returned empty/transient spaces
                if targetSpaceNum == nil, let cached = allBarWindowCache[win.id],
                   cached.displayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame {
                    targetSpaceNum = cached.window.spaceNumber
                }
                guard let sNum = targetSpaceNum else { continue }

                let dedupeKey = "\(bundle)_\(sNum)"
                if seenPerSpace.contains(dedupeKey) { continue }
                seenPerSpace.insert(dedupeKey)

                let cat = tilingCategory(for: win.id, spaceID: spaceIndexMap.first(where: { $0.value == sNum })?.key)
                let status: TilingWindowStatus
                switch cat {
                case "Left", "Left Column": status = .leftTabbed
                case "Right", "Right Column": status = .rightTabbed
                case "Float", "Floating": status = .floating
                default: status = .split
                }

                let barWindow = TilingBarWindow(
                    windowID: win.id,
                    pid: pid,
                    bundleID: bundle,
                    name: appName,
                    appName: appName,
                    title: win.title ?? appName,
                    icon: icon,
                    frame: frame,
                    isFocused: win.id == focusedID,
                    isShownInLayout: shownWindowIDs.contains(win.id),
                    status: status,
                    spaceNumber: sNum,
                    spaceName: "Desktop \(sNum)"
                )
                candidates.append(barWindow)
                allBarWindowCache[win.id] = CachedAllBarWindow(
                    window: barWindow,
                    displayUUID: displayUUID,
                    lastConfirmedAt: now
                )
            }
        }

        // Keep a real cached window when app enumeration momentarily omits it.
        // A window only genuinely closes when destroyed in WindowServer or its
        // process terminates. It must not disappear while parked on another Space.
        for (windowID, cachedValue) in Array(allBarWindowCache) {
            guard cachedValue.displayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame else { continue }
            guard registeredIDs.contains(windowID), runningPIDs.contains(cachedValue.window.pid) else {
                allBarWindowCache.removeValue(forKey: windowID)
                continue
            }
            let memberships = (TilingCGSCopySpacesForWindows(cid, 7, [windowID] as CFArray) as? [Int]) ?? []
            let mappedSpace: Int?
            if memberships.contains(currentSpaceID) {
                mappedSpace = currentSpaceNumber
            } else {
                mappedSpace = memberships.compactMap { spaceIndexMap[$0] }.first
            }
            let sNum = mappedSpace ?? cachedValue.window.spaceNumber

            let dedupeKey = "\(cachedValue.window.bundleID)_\(sNum)"
            if seenPerSpace.contains(dedupeKey) { continue }
            seenPerSpace.insert(dedupeKey)

            let cat = tilingCategory(for: windowID, spaceID: spaceIndexMap.first(where: { $0.value == sNum })?.key)
            let status: TilingWindowStatus
            switch cat {
            case "Left", "Left Column": status = .leftTabbed
            case "Right", "Right Column": status = .rightTabbed
            case "Float", "Floating": status = .floating
            default: status = cachedValue.window.status
            }
            let restored = TilingBarWindow(
                windowID: windowID,
                pid: cachedValue.window.pid,
                bundleID: cachedValue.window.bundleID,
                name: cachedValue.window.name,
                appName: cachedValue.window.appName,
                title: cachedValue.window.title,
                icon: cachedValue.window.icon,
                frame: cachedValue.window.frame,
                isFocused: windowID == focusedID,
                isShownInLayout: shownWindowIDs.contains(windowID),
                status: status,
                floatingIsAutomatic: cachedValue.window.floatingIsAutomatic,
                spaceNumber: sNum,
                spaceName: "Desktop \(sNum)"
            )
            candidates.append(restored)
            allBarWindowCache[windowID] = CachedAllBarWindow(
                window: restored,
                displayUUID: displayUUID,
                lastConfirmedAt: now
            )
        }

        let spaceNumbers = Array(Set(candidates.map(\.spaceNumber))).sorted()
        var orderedResults: [TilingBarWindow] = []
        for sNum in spaceNumbers {
            let spaceWins = candidates.filter { $0.spaceNumber == sNum }
            let spaceTreeIDs = states.first(where: {
                $0.key.displayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame &&
                spaceIndexMap[$0.key.spaceID] == sNum
            })?.value.tree?.windowIDs ?? []
            let ordered = stableOrderedWindows(spaceWins, displayUUID: displayUUID,
                                               spaceNumber: sNum, treeIDs: spaceTreeIDs)
            orderedResults.append(contentsOf: ordered)
        }
        return orderedResults
    }

    private func visibleWindows() -> [ManagedTilingWindow] {
        let windows = tileableWindows(onHiddenSpace: nil)
        lastWindowScan = (ProcessInfo.processInfo.systemUptime, windows)
        return windows
    }

    /// The last scan when it is only moments old. A scan asks every app for its
    /// windows and their geometry, which is main-thread work an app can take
    /// 10-20 ms to answer; a click does not need to pay that again when the
    /// poll just did it and tiling has held the windows still since.
    private func recentVisibleWindows() -> [ManagedTilingWindow] {
        if let scan = lastWindowScan,
           ProcessInfo.processInfo.systemUptime - scan.stamp < Self.windowScanReuseWindow {
            return scan.windows
        }
        return visibleWindows()
    }

    /// The windows tiling manages on screen now — or, given `hiddenSpace`, on
    /// a Desktop that isn't showing. Those are off-screen, so they come from
    /// the full window list filtered by Space, and `axWindow` falls through to
    /// its other-Space lookup to find them.
    private func tileableWindows(onHiddenSpace hiddenSpace: TilingSpaceKey?) -> [ManagedTilingWindow] {
        let options: CGWindowListOption = hiddenSpace == nil
            ? [.optionOnScreenOnly, .excludeDesktopElements] : [.excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let cid = TilingCGSMainConnectionID()
        var orderedIDs: [CGWindowID] = []
        var pids = Set<pid_t>()
        for info in raw {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  (info[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { continue }
            if let hiddenSpace {
                let spaces = (TilingCGSCopySpacesForWindows(cid, 7, [id] as CFArray) as? [Int]) ?? []
                guard spaces.contains(hiddenSpace.spaceID) else { continue }
            }
            orderedIDs.append(id)
            pids.insert(pid)
        }
        let visibleSet = Set(orderedIDs)
        var byID: [CGWindowID: ManagedTilingWindow] = [:]
        // Windows the last on-screen scan managed. A busy app (Edge playing
        // video) can miss the 0.15 s AX timeout; one slow answer must not drop
        // a window from tiling and the bar until the next poll.
        let previouslyManaged: [CGWindowID: ManagedTilingWindow] = hiddenSpace == nil
            ? Dictionary((lastWindowScan?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            : [:]
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular, !app.isHidden,
                  !SystemSearchOverlay.contains(app) else { continue }
            let icon = app.icon
            let appName = app.localizedName ?? "App"
            let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
            for candidate in WindowPreviewCapture.switcherWindows(pid: pid, scriptBrowsers: false)
                where candidate.id != 0 && visibleSet.contains(candidate.id) {
                let element = WindowPreviewCapture.axWindow(pid: pid, windowID: candidate.id)
                let manageable = element.map(manageability) ?? nil
                guard let element, manageable == true,
                      let axFrame = WindowPreviewCapture.axFrame(of: element) else {
                    // Unknown (timed out), not refused: keep the known window,
                    // at the frame WindowServer reports now.
                    if manageable != false, let known = previouslyManaged[candidate.id], known.pid == pid {
                        let frame = candidate.bounds.width > 0 ? axToAppKit(candidate.bounds) : known.frame
                        byID[candidate.id] = ManagedTilingWindow(
                            id: known.id, pid: known.pid, title: known.title, appName: known.appName,
                            icon: known.icon, element: known.element, frame: frame,
                            displayUUID: known.displayUUID, spaceIDs: known.spaceIDs,
                            automaticallyFloating: known.automaticallyFloating)
                    }
                    continue
                }
                let automaticallyFloating = automaticallyFloats(element, bundleID: bundleID)
                let frame = axToAppKit(axFrame)
                guard frame.width >= 160, frame.height >= 100,
                      let uuid = hiddenSpace?.displayUUID ?? screen(containing: frame)?.uuid else { continue }
                let spaces = (TilingCGSCopySpacesForWindows(cid, 7, [candidate.id] as CFArray) as? [Int]) ?? []
                byID[candidate.id] = ManagedTilingWindow(
                    id: candidate.id, pid: pid, title: candidate.title ?? appName,
                    appName: appName, icon: icon, element: element, frame: frame,
                    displayUUID: uuid, spaceIDs: spaces,
                    automaticallyFloating: automaticallyFloating
                )
            }
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    /// Whether tiling may manage the window: nil when the app didn't answer in
    /// time, which is not the same as saying no.
    private func manageability(_ window: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(window, 0.15)
        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        if subroleResult == .cannotComplete { return nil }
        guard subroleResult == .success,
              subrole as? String == kAXStandardWindowSubrole as String else { return false }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? NSNumber)?.boolValue == true { return false }
        var fullscreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
           (fullscreen as? NSNumber)?.boolValue == true { return false }
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionResult = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable)
        let sizeResult = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        if positionResult == .cannotComplete || sizeResult == .cannotComplete { return nil }
        return positionResult == .success && sizeResult == .success &&
            positionSettable.boolValue && sizeSettable.boolValue
    }

    /// One extra AX read per window on the refresh path — the identifier, which
    /// is the only thing that marks an in-process Open/Save dialog. Finder's own
    /// auxiliary windows need two more, and only Finder pays for those.
    private func automaticallyFloats(_ window: AXUIElement, bundleID: String) -> Bool {
        var identifierValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXIdentifier" as CFString, &identifierValue)
        var subroleValue: CFTypeRef?
        var documentValue: CFTypeRef?
        if bundleID == "com.apple.finder" {
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentValue)
        }
        return TilingLayout.shouldAutomaticallyFloat(
            bundleID: bundleID,
            identifier: identifierValue as? String,
            subrole: subroleValue as? String,
            document: documentValue as? String
        )
    }

    private func workspaceState(for key: TilingSpaceKey) -> TilingWorkspaceState {
        if var state = states[key] {
            state.mode = .masterStack
            return state
        }
        var state = TilingWorkspaceState()
        state.masterRatio = settings.tilingMasterRatio(for: key.displayUUID)
        return state
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(frame).area < b.frame.intersection(frame).area
        }.flatMap { $0.frame.intersects(frame) ? $0 : nil }
    }

    private func focusedWindowID() -> CGWindowID? {
        // A search overlay in front leaves nil here, so each Space falls back
        // to the window it last had focused instead of losing its focus.
        guard let app = NSWorkspace.shared.frontmostApplication,
              !SystemSearchOverlay.contains(app) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var id: CGWindowID = 0
        return TilingAXUIElementGetWindow(ref as! AXUIElement, &id) == .success && id != 0 ? id : nil
    }

    private func focusedDisplayUUID() -> String? {
        if let id = focusedWindowID(),
           let window = visibleWindows().first(where: { $0.id == id }) { return window.displayUUID }
        return NSScreen.main?.uuid
    }

    private func resolveSpace(displayUUID: String?, windowID: CGWindowID?, spaces: [TilingVisibleSpace], windows: [ManagedTilingWindow]) -> TilingVisibleSpace? {
        if let windowID, let win = windows.first(where: { $0.id == windowID }) {
            if let space = spaces.first(where: { $0.key.displayUUID.caseInsensitiveCompare(win.displayUUID) == .orderedSame && ($0.key.spaceID == 0 || win.spaceIDs.isEmpty || win.spaceIDs.contains($0.key.spaceID)) }) {
                return space
            }
        }
        if let displayUUID {
            if let space = spaces.first(where: { $0.key.displayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame }) {
                return space
            }
        }
        return spaces.first
    }

    private func togglePause(displayUUID: String?) {
        NSLog("MSG Tiling: togglePause displayUUID=%@", displayUUID ?? "nil")
        let spaces = visibleSpaces()
        guard let key = spaces.first(where: { displayUUID == nil || $0.key.displayUUID.caseInsensitiveCompare(displayUUID ?? "") == .orderedSame })?.key ?? spaces.first?.key else { return }
        var state = workspaceState(for: key)
        state.paused.toggle()
        states[key] = state
        refreshNow(forceLayout: !state.paused)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshNow(forceLayout: !state.paused)
        }
    }

    private func makeMaster(displayUUID: String?, windowID: CGWindowID? = nil) {
        NSLog("MSG Tiling: makeMaster displayUUID=%@ winID=%u", displayUUID ?? "nil", windowID ?? 0)
        let spaces = visibleSpaces()
        let windows = visibleWindows()
        guard let space = resolveSpace(displayUUID: displayUUID, windowID: windowID, spaces: spaces, windows: windows),
              let id = windowID ?? commandWindowID(on: space, windows: windows) else {
            NSLog("MSG Tiling: makeMaster failed to resolve space or window")
            return
        }
        guard windows.first(where: { $0.id == id })?.automaticallyFloating != true else { return }
        var state = workspaceState(for: space.key)
        state.floatingIDs.remove(id)
        state.mainTabIDs.insert(id)
        state.columnsInitialized = true
        state.masterID = id
        if state.stackID == id {
            state.stackID = state.tree?.windowIDs.first { !state.mainTabIDs.contains($0) }
        }
        state.mode = .masterStack
        states[space.key] = state
        refreshNow(forceLayout: true)
        DispatchQueue.main.async { [weak self] in self?.refreshNow(forceLayout: true) }
    }

    /// Moves a window between the two independent tab groups. Either side may
    /// become empty, in which case the remaining stack fills the work area.
    private func toggleMainTabGroup(displayUUID: String?, windowID: CGWindowID? = nil) {
        let spaces = visibleSpaces()
        let windows = visibleWindows()
        guard let space = resolveSpace(displayUUID: displayUUID, windowID: windowID,
                                       spaces: spaces, windows: windows),
              let id = windowID ?? commandWindowID(on: space, windows: windows),
              windows.first(where: { $0.id == id })?.automaticallyFloating != true else { return }
        var state = workspaceState(for: space.key)
        let treeIDs = state.tree?.windowIDs ?? []
        guard treeIDs.contains(id) else { return }
        state.floatingIDs.remove(id)
        state.mode = .masterStack
        state.columnsInitialized = true
        if state.mainTabIDs.contains(id) {
            state.mainTabIDs.remove(id)
            if state.masterID == id {
                state.masterID = treeIDs.first(where: { state.mainTabIDs.contains($0) })
            }
            state.stackID = id
        } else {
            state.mainTabIDs.insert(id)
            state.masterID = id
            if state.stackID == id {
                state.stackID = treeIDs.first { !state.mainTabIDs.contains($0) }
            }
        }
        states[space.key] = state
        refreshNow(forceLayout: true)
        DispatchQueue.main.async { [weak self] in self?.refreshNow(forceLayout: true) }
    }

    private func activateWindow(windowID: CGWindowID, pid: pid_t, frame: CGRect) {
        NSLog("[MSG Window Preview] Activate window %u pid %d", windowID, pid)
        let matchingKeys = states.compactMap { key, state in
            state.tree?.windowIDs.contains(windowID) == true ? key : nil
        }
        for key in matchingKeys {
            guard var state = states[key] else { continue }
            if state.mainTabIDs.contains(windowID) {
                state.masterID = windowID
            } else if !state.floatingIDs.contains(windowID) {
                state.stackID = windowID
            }
            state.lastFocusedID = windowID
            states[key] = state
        }
        Task { @MainActor [weak self] in
            if #available(macOS 14.0, *) {
                await WindowPreviewCapture.raiseWindow(pid: pid, windowID: windowID, fallbackBounds: frame)
            } else {
                let app = NSRunningApplication(processIdentifier: pid)
                app?.unhide()
                _ = app?.activate(options: [])
                if let window = WindowPreviewCapture.axWindow(pid: pid, windowID: windowID) {
                    AXUIElementSetAttributeValue(window, kAXMainWindowAttribute as CFString, true as CFTypeRef)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }
            self?.scheduleRefresh(after: 0.02)
        }
    }

    /// Hands a volume/brightness change to the control bar's Space Indicator.
    /// False when no bar is showing to take it, so the caller can fall back to
    /// the menu bar indicator.
    func showSystemHUD(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                       audioOutputKind: AudioOutputKind?) -> Bool {
        guard started, settings.tilingEnabled, settings.tilingShowControlBar else { return false }
        return controlBar.showSystemHUD(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
    }

    /// Hands an input source (keyboard language) change to the control bar's Space Indicator.
    /// False when no bar is showing to take it, so the caller can fall back to
    /// the menu bar indicator.
    func showInputSourceHUD(name: String) -> Bool {
        guard started, settings.tilingEnabled, settings.tilingShowControlBar else { return false }
        return controlBar.showInputSourceHUD(name: name)
    }

    /// The Desktop a click asked for on this display, while WindowServer is
    /// still reporting another. Nil — and forgotten — once `current` reaches
    /// it, or once it has outlived `programmaticTargetLifetime`.
    private func pendingProgrammaticTarget(for displayUUID: String, current: Int) -> Int? {
        let key = displayUUID.lowercased()
        guard let target = programmaticTargetSpaceByDisplay[key] else { return nil }
        let age = CACurrentMediaTime() - (programmaticTargetSetAt[key] ?? 0)
        guard target != current, age < Self.programmaticTargetLifetime else {
            programmaticTargetSpaceByDisplay.removeValue(forKey: key)
            programmaticTargetSetAt.removeValue(forKey: key)
            return nil
        }
        return target
    }

    private func switchToSpace(displayUUID: String, spaceNumber: Int) {
        guard let display = managedDisplay(displayUUID),
              let spaces = display["Spaces"] as? [[String: Any]],
              spaceNumber >= 1, spaceNumber <= spaces.count,
              let current = display["Current Space"] as? [String: Any] else { return }
        let currentID = managedSpaceID(current)
        guard currentID > 0,
              let currentIndex = spaces.firstIndex(where: { managedSpaceID($0) == currentID }) else { return }
        let targetIndex = spaceNumber - 1
        guard targetIndex != currentIndex else { return }

        let direction = targetIndex > currentIndex ? 1 : -1
        let steps = abs(targetIndex - currentIndex)
        let targetSpaceID = managedSpaceID(spaces[targetIndex])
        nativeSpaceSwitchGeneration &+= 1
        let generation = nativeSpaceSwitchGeneration
        programmaticTargetSpaceByDisplay[displayUUID.lowercased()] = spaceNumber
        programmaticTargetSetAt[displayUUID.lowercased()] = CACurrentMediaTime()
        updateControlBarSpaces()

        // Every Space-indicator click uses the same direct Desktop shortcut,
        // whether or not that Space currently contains a window. Previously
        // non-empty Spaces took the window-activation branch while empty ones
        // took this branch, producing inconsistent transitions and occasional
        // failed 2 <-> 3 switches.
        if targetSpaceID > 0, postConfiguredDirectSpaceShortcut(spaceNumber: spaceNumber) {
            waitForDirectSpaceLanding(displayUUID: displayUUID,
                                      targetSpaceID: targetSpaceID,
                                      generation: generation)
            return
        }

        // Retain app activation only as a fallback when the user has no direct
        // Desktop shortcut configured for this Space.
        if let targetWindow = representativeWindow(
            displayUUID: displayUUID,
            spaceNumber: spaceNumber
        ) {
            activateWindow(windowID: targetWindow.windowID,
                           pid: targetWindow.pid,
                           frame: targetWindow.frame)
            return
        }

        // Keep the instant gesture only as a compatibility fallback for Macs
        // where no direct Desktop shortcut or target window is available.
        let postedDirectly = postNativeSpaceJump(direction: direction, steps: steps)
        if targetSpaceID > 0, postedDirectly {
            waitForDirectSpaceLanding(displayUUID: displayUUID,
                                      targetSpaceID: targetSpaceID,
                                      generation: generation)
        } else {
            performNativeSpaceSwitchStep(displayUUID: displayUUID,
                                         direction: direction,
                                         remaining: steps,
                                         previousSpaceID: currentID,
                                         generation: generation)
        }
    }

    private func representativeWindow(displayUUID: String,
                                      spaceNumber: Int) -> TilingBarWindow? {
        let key = "\(displayUUID.lowercased())_\(spaceNumber)"
        let windows = (orderedWindowIDsBySpace[key] ?? []).compactMap {
            allBarWindowCache[$0]?.window
        }
        return windows.first(where: \.isShownInLayout) ??
            windows.first(where: { $0.status == .leftTabbed }) ??
            windows.first
    }

    private func managedDisplay(_ displayUUID: String) -> [String: Any]? {
        guard let displays = TilingCGSCopyManagedDisplaySpaces(TilingCGSMainConnectionID())
                as? [[String: Any]] else { return nil }
        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid
        return displays.first { display in
            var identifier = display["Display Identifier"] as? String ?? ""
            if identifier == "Main" { identifier = primaryUUID ?? "" }
            return identifier.caseInsensitiveCompare(displayUUID) == .orderedSame
        }
    }

    private func managedSpaceID(_ space: [String: Any]) -> Int {
        space["ManagedSpaceID"] as? Int ?? space["id64"] as? Int ?? 0
    }

    private func postNativeSpaceJump(direction: Int, steps: Int) -> Bool {
        guard steps > 0, steps <= Int(Int32.max) else { return false }
        return MSGPostSpaceJump(Int32(direction), Int32(steps)) != 0
    }

    private func postConfiguredDirectSpaceShortcut(spaceNumber: Int) -> Bool {
        // macOS symbolic hotkeys 118...133 are "Switch to Desktop 1...16".
        let hotkeyID = 117 + spaceNumber
        guard let hotkeys = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any],
              let entry = hotkeys[String(hotkeyID)] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber],
              parameters.count >= 3 else { return false }
        let keyCodeValue = parameters[1].uint16Value
        guard keyCodeValue != UInt16.max else { return false }
        return postNativeKeyShortcut(
            keyCode: CGKeyCode(keyCodeValue),
            flags: CGEventFlags(rawValue: parameters[2].uint64Value)
        )
    }

    @discardableResult
    private func postNativeKeyShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        // HID-system state is required for Mission Control shortcuts. A
        // combined-session source can be ignored even though posting reports
        // success, which previously made this path unreliable.
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func waitForDirectSpaceLanding(displayUUID: String, targetSpaceID: Int,
                                           generation: Int, attempt: Int = 0) {
        guard generation == nativeSpaceSwitchGeneration else { return }
        let currentID = managedDisplay(displayUUID)
            .flatMap { $0["Current Space"] as? [String: Any] }
            .map(managedSpaceID) ?? 0
        let isAnimating = TilingCGSManagedDisplayIsAnimating(
            TilingCGSMainConnectionID(), displayUUID as CFString
        )
        if currentID == targetSpaceID, !isAnimating {
            programmaticTargetSpaceByDisplay.removeValue(forKey: displayUUID.lowercased())
            lastWindowSignature = ""
            scheduleRefresh(after: 0.05)
            return
        }
        if currentID != targetSpaceID, attempt >= 12 {
            NSLog("MSG Tiling: direct Space jump did not land; using keyboard fallback on display %@",
                  displayUUID)
            performNativeSpaceSwitchFallback(displayUUID: displayUUID,
                                             targetSpaceID: targetSpaceID,
                                             generation: generation)
            return
        }
        guard attempt < 30 else {
            programmaticTargetSpaceByDisplay.removeValue(forKey: displayUUID.lowercased())
            NSLog("MSG Tiling: Space switch did not settle on display %@", displayUUID)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForDirectSpaceLanding(displayUUID: displayUUID,
                                            targetSpaceID: targetSpaceID,
                                            generation: generation,
                                            attempt: attempt + 1)
        }
    }

    private func performNativeSpaceSwitchFallback(displayUUID: String, targetSpaceID: Int,
                                                  generation: Int) {
        guard generation == nativeSpaceSwitchGeneration,
              let display = managedDisplay(displayUUID),
              let spaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any] else { return }
        let currentID = managedSpaceID(current)
        guard let currentIndex = spaces.firstIndex(where: { managedSpaceID($0) == currentID }),
              let targetIndex = spaces.firstIndex(where: { managedSpaceID($0) == targetSpaceID }),
              currentIndex != targetIndex else { return }
        let direction = targetIndex > currentIndex ? 1 : -1
        performNativeSpaceSwitchStep(displayUUID: displayUUID,
                                     direction: direction,
                                     remaining: abs(targetIndex - currentIndex),
                                     previousSpaceID: currentID,
                                     generation: generation)
    }

    private func postNativeSpaceStep(direction: Int) {
        let keyCode = CGKeyCode(direction > 0 ? 124 : 123)
        let shortcutFlags: CGEventFlags = [.maskControl, .maskSecondaryFn]
        postNativeKeyShortcut(keyCode: keyCode, flags: shortcutFlags)
    }

    private func performNativeSpaceSwitchStep(displayUUID: String, direction: Int,
                                              remaining: Int, previousSpaceID: Int,
                                              generation: Int) {
        guard generation == nativeSpaceSwitchGeneration, remaining > 0 else { return }
        postNativeSpaceStep(direction: direction)

        func waitForLanding(attempt: Int) {
            guard generation == nativeSpaceSwitchGeneration else { return }
            let currentID = managedDisplay(displayUUID)
                .flatMap { $0["Current Space"] as? [String: Any] }
                .map(managedSpaceID) ?? 0
            let isAnimating = TilingCGSManagedDisplayIsAnimating(
                TilingCGSMainConnectionID(), displayUUID as CFString
            )
            if currentID > 0, currentID != previousSpaceID, !isAnimating {
                if remaining > 1 {
                    performNativeSpaceSwitchStep(displayUUID: displayUUID,
                                                 direction: direction,
                                                 remaining: remaining - 1,
                                                 previousSpaceID: currentID,
                                                 generation: generation)
                } else {
                    programmaticTargetSpaceByDisplay.removeValue(forKey: displayUUID.lowercased())
                    lastWindowSignature = ""
                    scheduleRefresh(after: 0.05)
                }
                return
            }
            guard attempt < 30 else {
                programmaticTargetSpaceByDisplay.removeValue(forKey: displayUUID.lowercased())
                NSLog("MSG Tiling: keyboard Space fallback did not land on display %@", displayUUID)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForLanding(attempt: attempt + 1)
            }
        }
        waitForLanding(attempt: 0)
    }

    private func toggleFloating(displayUUID: String?, windowID: CGWindowID? = nil) {
        NSLog("MSG Tiling: toggleFloating displayUUID=%@ winID=%u", displayUUID ?? "nil", windowID ?? 0)
        let spaces = visibleSpaces()
        let windows = visibleWindows()
        guard let space = resolveSpace(displayUUID: displayUUID, windowID: windowID, spaces: spaces, windows: windows),
              let id = windowID ?? commandWindowID(on: space, windows: windows) else {
            NSLog("MSG Tiling: toggleFloating failed to resolve space or window")
            return
        }
        if windows.first(where: { $0.id == id })?.automaticallyFloating == true { return }
        var state = workspaceState(for: space.key)
        if state.floatingIDs.contains(id) {
            state.floatingIDs.remove(id)
        } else {
            state.floatingIDs.insert(id)
            state.mainTabIDs.remove(id)
            if state.masterID == id {
                state.masterID = state.tree?.windowIDs.first { state.mainTabIDs.contains($0) }
            }
            if state.stackID == id { state.stackID = nil }
        }
        states[space.key] = state
        refreshNow(forceLayout: true)
        DispatchQueue.main.async { [weak self] in self?.refreshNow(forceLayout: true) }
    }

    private func makeFloating(displayUUID: String?, windowID: CGWindowID? = nil) {
        NSLog("MSG Tiling: makeFloating displayUUID=%@ winID=%u", displayUUID ?? "nil", windowID ?? 0)
        let spaces = visibleSpaces()
        let windows = visibleWindows()
        guard let space = resolveSpace(displayUUID: displayUUID, windowID: windowID, spaces: spaces, windows: windows),
              let id = windowID ?? commandWindowID(on: space, windows: windows) else { return }
        var state = workspaceState(for: space.key)
        state.floatingIDs.insert(id)
        state.mainTabIDs.remove(id)
        if state.masterID == id {
            state.masterID = state.tree?.windowIDs.first { state.mainTabIDs.contains($0) }
        }
        if state.stackID == id { state.stackID = nil }
        states[space.key] = state
        refreshNow(forceLayout: true)
        DispatchQueue.main.async { [weak self] in self?.refreshNow(forceLayout: true) }
    }

    private func commandWindowID(on space: TilingVisibleSpace, windows: [ManagedTilingWindow]) -> CGWindowID? {
        let ids = windows.filter {
            $0.displayUUID == space.key.displayUUID &&
            ($0.spaceIDs.isEmpty || $0.spaceIDs.contains(space.key.spaceID)) &&
            !$0.automaticallyFloating
        }.map(\.id)
        if let focused = focusedWindowID(), ids.contains(focused) { return focused }
        if let last = states[space.key]?.lastFocusedID, ids.contains(last) { return last }
        return ids.first
    }

    private func currentWindowSignature() -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return "" }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var isMC = false
        let ids = list.compactMap { info -> String? in
            let owner = info[kCGWindowOwnerName as String] as? String
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            if !isMC, owner == "WindowManager", layer > 0, layer < 1000 {
                if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                    if MissionControlDetector.overlayNames.contains(name) { isMC = true }
                } else {
                    isMC = true
                }
            }
            guard layer == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != myPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return "\(id):\(bounds["X"] ?? 0):\(bounds["Y"] ?? 0):\(bounds["Width"] ?? 0):\(bounds["Height"] ?? 0)"
        }
        if isMC { return "mission_control" }
        let spaces = visibleSpaces().map { "\($0.key.displayUUID):\($0.key.spaceID):\($0.screen.visibleFrame)" }.joined(separator: ",")
        return "\(settings.tilingControlBarScope.rawValue)|" + spaces + "|" + ids.joined(separator: ",")
    }

    private func visibleSpaces() -> [TilingVisibleSpace] {
        guard let raw = TilingCGSCopyManagedDisplaySpaces(TilingCGSMainConnectionID()) as? [[String: Any]] else { return [] }
        let primaryUUID = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.uuid
        return raw.compactMap { display in
            var uuid = display["Display Identifier"] as? String ?? ""
            if uuid == "Main" { uuid = primaryUUID ?? "" }
            guard !uuid.isEmpty,
                  let screen = NSScreen.screens.first(where: { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }),
                  let current = display["Current Space"] as? [String: Any] else { return nil }
            let id = current["ManagedSpaceID"] as? Int ?? current["id64"] as? Int ?? 0
            guard id > 0 else { return nil }
            let all = display["Spaces"] as? [[String: Any]] ?? []
            let index = (all.firstIndex { ($0["ManagedSpaceID"] as? Int ?? $0["id64"] as? Int) == id } ?? 0) + 1
            return TilingVisibleSpace(key: .init(displayUUID: uuid, spaceID: id), number: index,
                                      total: max(1, all.count),
                                      screen: screen, isFullscreen: (current["type"] as? Int) == 4)
        }
    }

    private var primaryMaxY: CGFloat {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        })?.frame.maxY ?? 0
    }

    private func axToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func appKitToAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func categoryPriority(_ status: TilingWindowStatus) -> Int {
        switch status {
        case .leftTabbed: return 0
        case .rightTabbed: return 1
        case .split: return 2
        case .floating: return 3
        case .paused: return 4
        }
    }

    func tilingCategory(for windowID: CGWindowID, spaceID: Int? = nil) -> String {
        if let spaceID {
            for (key, state) in states where key.spaceID == spaceID {
                if state.floatingIDs.contains(windowID) { return "Float" }
                let treeIDs = state.tree?.windowIDs ?? []
                if treeIDs.contains(windowID) {
                    if state.mode == .masterStack {
                        return state.mainTabIDs.contains(windowID) ? "Left" : "Right"
                    } else {
                        return (treeIDs.count > 1 && windowID != (state.masterID ?? treeIDs.first)) ? "Split" : "Master"
                    }
                }
            }
        }
        for (_, state) in states {
            if state.floatingIDs.contains(windowID) {
                return "Float"
            }
            let treeIDs = state.tree?.windowIDs ?? []
            if treeIDs.contains(windowID) {
                if state.mode == .masterStack {
                    return state.mainTabIDs.contains(windowID) ? "Left" : "Right"
                } else {
                    return (treeIDs.count > 1 && windowID != (state.masterID ?? treeIDs.first)) ? "Split" : "Master"
                }
            }
        }
        return "Float"
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}
