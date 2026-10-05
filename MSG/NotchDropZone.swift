import AppKit
import AVFoundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Dropping files on the notch
//
// Drag a file, picture or video toward the notch and it grows into the same
// black card as the other notch UI, with two places to let go: the Tray, which
// keeps the files on a shelf (the TokenBar dashboard shows it as a page), and
// AirDrop, which opens the share sheet for them.
//
// A drag is spotted from the mouse events alone (the global monitors see other
// apps' drags), and the drag pasteboard is read once per drag, only when the
// pointer first reaches the notch. Nothing here repeats on a timer; the only
// timers are the short ones that close the card.

// MARK: - The shelf

/// The files the user parked on the notch: file URLs, newest first. Main thread.
final class NotchTray {
    static let shared = NotchTray()

    static let limit = 30

    /// Where files that arrive as promises (an image dragged out of a browser or
    /// Photos) are received. The tray holds that copy, so it owns it: removing
    /// the item deletes it.
    static let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/H1D3S1GN.MSG/Tray", isDirectory: true)

    private static let key = "notchTrayItems"

    private(set) var items: [URL] = []
    private var observers: [() -> Void] = []

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        var seen = Set<String>()
        items = saved
            .filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .prefix(Self.limit)
            .map { URL(fileURLWithPath: $0) }
        if items.count != saved.count { persist() }
        sweepCache()
    }

    /// Called on main whenever the items change.
    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }

    /// New files go to the front; one already here moves up rather than twice.
    func add(_ urls: [URL]) {
        let fresh = urls.filter(\.isFileURL).map { $0.standardizedFileURL }
        guard !fresh.isEmpty else { return }
        var seen = Set<String>()
        let merged = (fresh + items).filter { seen.insert($0.path).inserted }
        items = Array(merged.prefix(Self.limit))
        merged.dropFirst(Self.limit).forEach(Self.discard)
        persist()
        notify()
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard items.contains(where: { $0.path == path }) else { return }
        items.removeAll { $0.path == path }
        Self.discard(url)
        persist()
        notify()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.forEach(Self.discard)
        items = []
        persist()
        notify()
    }

    /// Forgets files that were moved or deleted since they were dropped. Quiet:
    /// whoever asks is about to read `items` anyway.
    func pruneMissing() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard alive.count != items.count else { return }
        items = alive
        persist()
    }

    private func notify() { observers.forEach { $0() } }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.key)
    }

    /// Only copies the tray made are deleted, never a file the user dropped from
    /// Finder. Each received file sits alone in its own folder, which goes too.
    private static func discard(_ url: URL) {
        guard cacheEntry(of: url) != nil else { return }
        let folder = url.deletingLastPathComponent()
        let alone = folder.deletingLastPathComponent().standardizedFileURL.path == cacheDirectory.standardizedFileURL.path
        try? FileManager.default.removeItem(at: alone ? folder : url)
    }

    /// The top-level cache entry holding `url`, nil for a file outside the cache.
    private static func cacheEntry(of url: URL) -> String? {
        let root = cacheDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return path.dropFirst(root.count).split(separator: "/").first.map(String.init)
    }

    /// Copies nobody holds any more (an AirDrop's, one left by a crash), swept
    /// once at launch. Anything fresh is left alone: a drop may be arriving.
    private func sweepCache() {
        let keep = Set(items.compactMap(Self.cacheEntry))
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: Self.cacheDirectory,
                                                            includingPropertiesForKeys: [.contentModificationDateKey])
            else { return }
            for entry in entries where !keep.contains(entry.lastPathComponent) {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > 60 { try? fm.removeItem(at: entry) }
            }
        }
    }
}

// MARK: - Reading a drop

/// What a drag can carry and how to turn it into files: file URLs as they are,
/// file promises received into the tray's cache, a bare image written out as a
/// PNG. The tray's targets, the AirDrop target and the tray page all use it.
enum NotchDropReader {
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let movie = NSPasteboard.PasteboardType("public.movie")

    static var promiseTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// What the drop targets register for.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .tiff, .png, jpeg] + promiseTypes
    }

    /// Whether a drag's pasteboard is worth showing the card for.
    static func carriesFiles(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let wanted = Set([.fileURL, .tiff, .png, jpeg, movie] + promiseTypes)
        return types.contains { wanted.contains($0) }
    }

    /// The operation to answer a hovering drag with: whichever of copy, generic
    /// and link the source allows, so a source that forbids copying still drops.
    static func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for operation in [NSDragOperation.copy, .generic, .link] where mask.contains(operation) { return operation }
        return []
    }

    /// False when the pasteboard holds nothing to take. Otherwise `completion`
    /// follows on main, later: promises can take a while, and a drop shouldn't
    /// start a share sheet from inside AppKit's own drag handling.
    static func read(_ pasteboard: NSPasteboard, completion: @escaping ([URL]) -> Void) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            DispatchQueue.main.async { completion(urls) }
            return true
        }
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                                options: nil) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty {
            receive(receivers, completion: completion)
            return true
        }
        return receiveImage(pasteboard, completion: completion)
    }

    /// A fresh folder of its own, so two files with one name never collide and a
    /// file can be removed together with its folder.
    private static func uniqueFolder() -> URL {
        let folder = NotchTray.cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private final class Batch {
        private let lock = NSLock()
        private var urls: [URL?]
        init(count: Int) { urls = Array(repeating: nil, count: count) }
        func set(_ url: URL, at index: Int) { lock.lock(); urls[index] = url; lock.unlock() }
        var received: [URL] { lock.lock(); defer { lock.unlock() }; return urls.compactMap { $0 } }
    }

    private static func receive(_ receivers: [NSFilePromiseReceiver], completion: @escaping ([URL]) -> Void) {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let batch = Batch(count: receivers.count)
        let group = DispatchGroup()
        for (index, receiver) in receivers.enumerated() {
            group.enter()
            receiver.receivePromisedFiles(atDestination: uniqueFolder(), options: [:], operationQueue: queue) { url, error in
                if error == nil { batch.set(url, at: index) }
                group.leave()
            }
        }
        // The receivers stay alive in this closure until every file has arrived.
        group.notify(queue: .main) {
            withExtendedLifetime(receivers) { completion(batch.received) }
        }
    }

    private static func receiveImage(_ pasteboard: NSPasteboard, completion: @escaping ([URL]) -> Void) -> Bool {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return false }
        DispatchQueue.global(qos: .userInitiated).async {
            let formatter = DateFormatter()
            // A fixed calendar: the user's may count years differently (Buddhist).
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = uniqueFolder().appendingPathComponent("Image \(formatter.string(from: Date())).png")
            let written = (try? png.write(to: url)) != nil
            DispatchQueue.main.async { completion(written ? [url] : []) }
        }
        return true
    }
}

// MARK: - The drop card

final class NotchDropZone {
    static let shared = NotchDropZone()

    /// Asked before the card opens; true keeps it away. The dashboard can use it
    /// to take the drop itself while it's open (the card would fold it away).
    var isSuppressed: (() -> Bool)?

    private(set) var isShowing = false

    /// How far the trigger reaches past the notch's sides and below it.
    private static let wing: CGFloat = 140
    private static let reach: CGFloat = 90
    /// The card is the notch's height plus this.
    private static let body: CGFloat = 110
    /// The pointer must be out this long before the card folds away.
    private static let leaveHold: TimeInterval = 0.3
    /// A drag let go over the card gets this long for the drop to arrive.
    private static let dropGrace: TimeInterval = 0.6

    private enum Verdict { case unknown, files, other }

    private var monitors: [Any] = []
    private var observing = false
    private var verdict = Verdict.unknown
    /// The drag pasteboard's change count at the last mouse down or up: a drag
    /// that carries something wrote it since.
    private var baseline = 0
    private var lastDrag: CFTimeInterval = 0

    private var panel: NSPanel?
    private var host: NotchShapeHostView?
    private let view = NotchDropView()
    private var notch: CGRect = .zero
    private var leaveWork: DispatchWorkItem?
    private var graceWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    /// The share sheet closes when its service goes, so the last one is kept.
    private var airDrop: NSSharingService?

    private init() {
        view.onAccepted = { [weak self] in
            // After AppKit has finished with the drop, not inside it.
            DispatchQueue.main.async { self?.close(animated: true) }
        }
        view.onFiles = { [weak self] kind, urls in self?.receive(kind, urls) }
    }

    func start() {
        // Loaded now so its stale-copy sweep runs at launch, not mid-drop.
        _ = NotchTray.shared
        observe()
        guard monitors.isEmpty else { return }
        baseline = NSPasteboard(name: .drag).changeCount
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        verdict = .unknown
        close(animated: false)
    }

    // MARK: Drags

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A new gesture: whatever the last drag carried no longer counts.
            verdict = .unknown
            baseline = NSPasteboard(name: .drag).changeCount
        case .leftMouseUp:
            dragEnded()
        case .leftMouseDragged:
            dragMoved()
        default:
            break
        }
    }

    private func dragMoved() {
        let now = CACurrentMediaTime()
        guard now - lastDrag >= 0.03 else { return }
        lastDrag = now
        guard PresentationState.shared.canPresent, let screen = AgentNotchCard.notchScreen() else {
            close(animated: false)
            return
        }
        let notch = AgentNotchCard.notchRect(screen)
        let point = NSEvent.mouseLocation
        let trigger = Self.trigger(notch, screen)

        if isShowing, let panel {
            if trigger.union(panel.frame.insetBy(dx: -8, dy: -8)).contains(point) {
                leaveWork?.cancel()
                leaveWork = nil
            } else if leaveWork == nil {
                scheduleLeave()
            }
            return
        }
        guard trigger.contains(point), carriesFiles(), isSuppressed?() != true else { return }
        show(on: screen, notch: notch)
    }

    /// Looked at once per drag, the first time the pointer is at the notch: a
    /// plain mouse drag (a window, a selection) never wrote the drag pasteboard.
    private func carriesFiles() -> Bool {
        if verdict == .unknown {
            let pasteboard = NSPasteboard(name: .drag)
            let carries = pasteboard.changeCount != baseline
                && !NotchTrayPane.isDraggingOut
                && NotchDropReader.carriesFiles(pasteboard.types ?? [])
            verdict = carries ? .files : .other
        }
        return verdict == .files
    }

    private func dragEnded() {
        verdict = .unknown
        baseline = NSPasteboard(name: .drag).changeCount
        leaveWork?.cancel()
        leaveWork = nil
        guard isShowing, let panel else { return }
        guard panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) else {
            close(animated: true)
            return
        }
        // Let go over the card: the drop is on its way, and closing now would
        // cancel it. It closes the card itself; if none comes, this does.
        graceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close(animated: true) }
        graceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropGrace, execute: work)
    }

    private func scheduleLeave() {
        let work = DispatchWorkItem { [weak self] in
            self?.leaveWork = nil
            guard let self, self.isShowing, let panel = self.panel else { return }
            guard let screen = AgentNotchCard.notchScreen() else {
                self.close(animated: true)
                return
            }
            let keep = Self.trigger(AgentNotchCard.notchRect(screen), screen).union(panel.frame.insetBy(dx: -8, dy: -8))
            if !keep.contains(NSEvent.mouseLocation) { self.close(animated: true) }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveHold, execute: work)
    }

    /// The notch widened and extended down. It runs a little above the screen's
    /// edge too: a pointer pinned to the top reads exactly the edge, which a
    /// rect doesn't contain.
    private static func trigger(_ notch: CGRect, _ screen: NSScreen) -> CGRect {
        let bottom = notch.minY - reach
        return CGRect(x: notch.minX - wing, y: bottom,
                      width: notch.width + 2 * wing, height: screen.frame.maxY + 2 - bottom)
    }

    // MARK: Showing

    private func show(on screen: NSScreen, notch: CGRect) {
        guard PresentationState.shared.canPresent else { return }
        AgentNotchCard.shared.yieldToHUD()
        if NotchHUD.shared.isShowing { NotchHUD.shared.hide(animated: false) }
        let panel = self.panel ?? makePanel()
        guard let host else { return }
        orderOutWork?.cancel()
        orderOutWork = nil
        graceWork?.cancel()
        graceWork = nil
        self.notch = notch

        view.reset()
        view.configure(notchHeight: notch.height, trayCount: NotchTray.shared.items.count)
        let width = notch.width + 2 * Self.wing
        let height = notch.height + Self.body
        let target = CGRect(x: (notch.midX - width / 2).rounded(), y: screen.frame.maxY - height,
                            width: width, height: height)
        panel.setFrame(target, display: false)
        host.layout(notch: notch, in: target)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        host.animateOpen()
        isShowing = true
    }

    func close(animated: Bool) {
        leaveWork?.cancel()
        leaveWork = nil
        graceWork?.cancel()
        graceWork = nil
        guard isShowing, let panel, let host else { return }
        isShowing = false
        panel.ignoresMouseEvents = true
        guard animated else {
            orderOutWork?.cancel()
            orderOutWork = nil
            panel.orderOut(nil)
            return
        }
        host.animateClosed()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchShapeHostView.closeDuration + 0.05, execute: work)
    }

    // MARK: Drops

    private func receive(_ kind: NotchDropTarget.Kind, _ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch kind {
        case .tray:
            NotchTray.shared.add(urls)
        case .airDrop:
            // The share sheet only comes forward for an active app.
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                airDrop = NSSharingService(named: .sendViaAirDrop)
                airDrop?.perform(withItems: urls)
            }
        }
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.pongsiri.cortex.notch.opened"),
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.close(animated: false)
        }
        PresentationState.shared.addObserver { [weak self] in
            if !PresentationState.shared.canPresent { self?.close(animated: false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.close(animated: false)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NotchTransition.windowLevel
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        let host = NotchShapeHostView(content: view)
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

// MARK: - Card contents

/// Flipped: laid out from the top of the card, which is the screen's top edge.
/// Two equal targets under the notch's band.
final class NotchDropView: NSView {
    /// A drop was taken (its files may still be arriving): the card can go.
    var onAccepted: (() -> Void)?
    var onFiles: ((NotchDropTarget.Kind, [URL]) -> Void)?

    private static let padding: CGFloat = 20
    private static let gap: CGFloat = 12

    private let tray = NotchDropTarget(kind: .tray)
    private let airDrop = NotchDropTarget(kind: .airDrop)
    private var band: CGFloat = 32

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for target in [tray, airDrop] {
            let kind = target.kind
            target.onAccepted = { [weak self] in self?.onAccepted?() }
            target.onFiles = { [weak self] urls in self?.onFiles?(kind, urls) }
            addSubview(target)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(notchHeight: CGFloat, trayCount: Int) {
        band = notchHeight
        tray.detail = trayCount == 0 ? "" : trayCount == 1 ? "1 file" : "\(trayCount) files"
        // Both targets keep room for the line so their icons stay level.
        tray.reservesDetail = trayCount > 0
        airDrop.reservesDetail = trayCount > 0
        needsLayout = true
    }

    /// Opening afresh: nothing hovered, whatever the last drag left behind.
    func reset() {
        tray.setHovered(false, animated: false)
        airDrop.setHovered(false, animated: false)
    }

    override func layout() {
        super.layout()
        let pad = Self.padding
        let top = band + pad
        let width = (bounds.width - 2 * pad - Self.gap) / 2
        let height = max(0, bounds.height - top - pad)
        tray.frame = CGRect(x: pad, y: top, width: width, height: height)
        airDrop.frame = CGRect(x: pad + width + Self.gap, y: top, width: width, height: height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One place to let go. A drag hovering it lights it up and swells it a touch.
final class NotchDropTarget: NSView {
    enum Kind { case tray, airDrop }

    let kind: Kind
    var onAccepted: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var detail = "" { didSet { detailLabel.stringValue = detail; needsLayout = true } }
    var reservesDetail = false { didSet { needsLayout = true } }
    private(set) var isHovered = false

    private static let hoverScale: CGFloat = 1.04
    private let icon = NSImageView()
    private let label: NSTextField
    private let detailLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(kind: Kind) {
        self.kind = kind
        label = NSTextField(labelWithString: kind == .tray ? "Tray" : "AirDrop")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Self.fill(hovered: false)

        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        icon.image = Self.symbol(kind)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.5)
        detailLabel.alignment = .center
        for view in [icon, label, detailLabel] as [NSView] { addSubview(view) }
        // An image view takes image drops of its own: over the icon, the drag
        // would leave this target and land on nothing.
        icon.unregisterDraggedTypes()
        registerForDraggedTypes(NotchDropReader.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func fill(hovered: Bool) -> CGColor {
        NSColor(white: 1, alpha: hovered ? 0.18 : 0.08).cgColor
    }

    private static func symbol(_ kind: Kind) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let names = kind == .tray ? ["tray.and.arrow.down.fill"] : ["airdrop", "dot.radiowaves.left.and.right"]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image.withSymbolConfiguration(config)
            }
        }
        return nil
    }

    override func layout() {
        super.layout()
        // Icon over label, centred as a block (with room for the detail line
        // when either target has one, so the two icons sit at one height).
        let iconHeight: CGFloat = 24, labelHeight: CGFloat = 16, detailHeight: CGFloat = 14
        let block = iconHeight + 3 + labelHeight + (reservesDetail ? 1 + detailHeight : 0)
        let top = ((bounds.height - block) / 2).rounded()
        icon.frame = CGRect(x: 0, y: top, width: bounds.width, height: iconHeight)
        label.frame = CGRect(x: 6, y: top + iconHeight + 3, width: bounds.width - 12, height: labelHeight)
        detailLabel.frame = CGRect(x: 6, y: top + iconHeight + 3 + labelHeight + 1,
                                   width: bounds.width - 12, height: detailHeight)
        detailLabel.isHidden = detail.isEmpty
    }

    func setHovered(_ on: Bool, animated: Bool = true) {
        guard on != isHovered, let layer else { return }
        isHovered = on
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let fromColor = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        let transform = scale(on ? Self.hoverScale : 1, in: layer)
        let color = Self.fill(hovered: on)
        layer.transform = transform
        layer.backgroundColor = color
        layer.removeAnimation(forKey: "hoverScale")
        layer.removeAnimation(forKey: "hoverFill")
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: fromTransform)
        grow.toValue = NSValue(caTransform3D: transform)
        grow.duration = 0.16
        grow.timingFunction = NotchTransition.timingFunction
        layer.add(grow, forKey: "hoverScale")
        let light = CABasicAnimation(keyPath: "backgroundColor")
        light.fromValue = fromColor
        light.toValue = color
        light.duration = 0.12
        layer.add(light, forKey: "hoverFill")
    }

    /// Scaled about the middle whatever the layer's anchor point is.
    private func scale(_ factor: CGFloat, in layer: CALayer) -> CATransform3D {
        let bounds = layer.bounds, anchor = layer.anchorPoint
        let shift = CATransform3DMakeTranslation((bounds.width / 2 - anchor.x * bounds.width) * (1 - factor),
                                                 (bounds.height / 2 - anchor.y * bounds.height) * (1 - factor), 0)
        return CATransform3DScale(shift, factor, factor, 1)
    }

    // MARK: Drag destination

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = NotchDropReader.operation(for: sender)
        setHovered(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        NotchDropReader.operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setHovered(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHovered(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHovered(false)
        let accepted = NotchDropReader.read(sender.draggingPasteboard) { [weak self] urls in self?.onFiles?(urls) }
        if accepted { onAccepted?() }
        return accepted
    }
}

// MARK: - The tray's page

/// The shelf's contents as a grid of tiles, for the notch dashboard. Tiles drag
/// out into Finder, Mail or a browser; the pane takes drops of its own.
final class NotchTrayPane: NSView {
    /// True while one of our own tiles is being dragged: the notch's drop card
    /// and this pane both stay out of it.
    static var isDraggingOut = false

    /// The height the page needs may have changed (files came or went).
    var onContentChanged: (() -> Void)?

    private static let padding: CGFloat = 24
    private static let gap: CGFloat = 12
    private static let clearRow: CGFloat = 18
    private static let emptyRow: CGFloat = 17

    private let emptyLabel = NSTextField(labelWithString: "Drop files on the notch to keep them here")
    private let clearButton = NotchTrayTextButton(title: "Clear")
    private var tiles: [NotchTrayTile] = []
    private var outgoingTiles: [NotchTrayTile] = []
    private var heldHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.55)
        emptyLabel.lineBreakMode = .byTruncatingTail
        clearButton.onClick = { NotchTray.shared.clear() }
        addSubview(emptyLabel)
        addSubview(clearButton)
        registerForDraggedTypes(NotchDropReader.acceptedTypes)
        NotchTray.shared.addObserver { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        NotchTray.shared.pruneMissing()
        let items = NotchTray.shared.items
        guard items.map(\.path) != tiles.map(\.url.path) else { return }
        let before = tiles.count
        let beforeHeight = fittingHeight(width: bounds.width)
        var reusable = tiles.reduce(into: [String: NotchTrayTile]()) { $0[$1.url.path] = $1 }
        tiles = items.map { url in
            reusable.removeValue(forKey: url.path) ?? makeTile(url)
        }
        let removed = Array(reusable.values)
        if !removed.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            heldHeight = max(heldHeight, beforeHeight)
            outgoingTiles.append(contentsOf: removed)
            for tile in removed {
                tile.wantsLayer = true
                tile.layer?.opacity = 0
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.22
                tile.layer?.add(fade, forKey: "trayRemoval")
                let slide = CABasicAnimation(keyPath: "transform.translation.y")
                slide.fromValue = 0
                slide.toValue = -8
                slide.duration = 0.22
                slide.timingFunction = CAMediaTimingFunction(name: .easeIn)
                tile.layer?.add(slide, forKey: "trayRemovalSlide")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else { return }
                removed.forEach { $0.removeFromSuperview() }
                self.outgoingTiles.removeAll { tile in removed.contains { $0 === tile } }
                if self.outgoingTiles.isEmpty { self.heldHeight = 0 }
                self.needsLayout = true
                self.onContentChanged?()
            }
        } else { removed.forEach { $0.removeFromSuperview() } }
        for tile in tiles where tile.superview == nil { addSubview(tile) }
        needsLayout = true
        if before != tiles.count, outgoingTiles.isEmpty || !tiles.isEmpty { onContentChanged?() }
    }

    private func makeTile(_ url: URL) -> NotchTrayTile {
        let tile = NotchTrayTile(url: url)
        tile.onRemove = { NotchTray.shared.remove(url) }
        return tile
    }

    private func columns(for width: CGFloat) -> Int {
        let inner = width - 2 * Self.padding
        return max(1, Int((inner + Self.gap) / (NotchTrayTile.size.width + Self.gap)))
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard !tiles.isEmpty else { return max(heldHeight, Self.padding * 2 + Self.emptyRow) }
        let rows = (tiles.count + columns(for: width) - 1) / columns(for: width)
        let grid = CGFloat(rows) * NotchTrayTile.size.height + CGFloat(rows - 1) * Self.gap
        return max(heldHeight, Self.padding + Self.clearRow + 6 + grid + Self.padding)
    }

    override func layout() {
        super.layout()
        let pad = Self.padding
        emptyLabel.isHidden = !tiles.isEmpty || !outgoingTiles.isEmpty
        clearButton.isHidden = tiles.isEmpty
        emptyLabel.frame = CGRect(x: pad, y: pad, width: max(0, bounds.width - 2 * pad), height: Self.emptyRow)
        guard !tiles.isEmpty else { return }

        clearButton.frame.origin = CGPoint(x: bounds.width - pad + 6 - clearButton.frame.width,
                                           y: pad + (Self.clearRow - clearButton.frame.height) / 2)
        // The grid is centred in what the whole columns leave over.
        let columns = self.columns(for: bounds.width)
        let tile = NotchTrayTile.size
        let used = CGFloat(columns) * tile.width + CGFloat(columns - 1) * Self.gap
        let left = pad + ((bounds.width - 2 * pad - used) / 2).rounded(.down)
        let top = pad + Self.clearRow + 6
        for (index, view) in tiles.enumerated() {
            view.frame = CGRect(x: left + CGFloat(index % columns) * (tile.width + Self.gap),
                                y: top + CGFloat(index / columns) * (tile.height + Self.gap),
                                width: tile.width, height: tile.height)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.isDraggingOut ? [] : NotchDropReader.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.isDraggingOut ? [] : NotchDropReader.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !Self.isDraggingOut else { return false }
        return NotchDropReader.read(sender.draggingPasteboard) { NotchTray.shared.add($0) }
    }
}

// MARK: - Tile

/// One file: its icon (a thumbnail for pictures and videos), its name, and a
/// × on hover that takes it off the shelf. Drag it out to use the file; a
/// double-click opens it.
final class NotchTrayTile: NSView, NSDraggingSource {
    static let size = CGSize(width: 84, height: 96)

    let url: URL
    var onRemove: (() -> Void)?

    private static let nameFont = NSFont.systemFont(ofSize: 11)
    private static let iconSize: CGFloat = 48

    private let icon = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let close = NotchTrayCloseButton()
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    private var hovered = false {
        didSet {
            layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.08 : 0).cgColor
            close.isHidden = !hovered
        }
    }

    override var isFlipped: Bool { true }

    init(url: URL) {
        self.url = url
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        icon.image = image
        icon.imageScaling = .scaleProportionallyDown
        name.stringValue = Self.fitted(url.lastPathComponent)
        name.font = Self.nameFont
        name.textColor = NSColor(white: 1, alpha: 0.85)
        name.alignment = .center
        name.isSelectable = false
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byWordWrapping
        name.cell?.truncatesLastVisibleLine = true
        close.isHidden = true
        close.onClick = { [weak self] in self?.onRemove?() }
        for view in [icon, name, close] as [NSView] { addSubview(view) }
        // Drops over a tile belong to the pane, not the tile's image view.
        icon.unregisterDraggedTypes()
        loadThumbnail()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Pictures and videos show themselves rather than their kind's icon; the
    /// icon stays until (and unless) the thumbnail arrives. ImageIO and
    /// AVFoundation, not QuickLook: its module doesn't build with the private
    /// frameworks path the build uses.
    private func loadThumbnail() {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        let isImage = type.conforms(to: .image)
        guard isImage || type.conforms(to: .movie) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Self.iconSize * scale
        let url = self.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let picture: CGImage?
            if isImage {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: pixels]
                picture = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                    CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary)
                }
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: pixels, height: pixels)
                picture = try? generator.copyCGImage(at: .zero, actualTime: nil)
            }
            guard let picture else { return }
            let size = NSSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale)
            DispatchQueue.main.async { self?.icon.image = NSImage(cgImage: picture, size: size) }
        }
    }

    /// A label set up like the tile's, but with no line limit: it says how tall
    /// a name really wraps, which is what decides whether it needs cutting.
    private static let meter: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = nameFont
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }()

    /// The name cut in the middle, keeping its end (the extension), so that it
    /// fits two lines.
    private static func fitted(_ name: String) -> String {
        let line = NSLayoutManager().defaultLineHeight(for: nameFont)
        func fits(_ text: String) -> Bool {
            meter.stringValue = text
            let bounds = NSRect(x: 0, y: 0, width: Self.size.width - 4, height: .greatestFiniteMagnitude)
            return (meter.cell?.cellSize(forBounds: bounds).height ?? 0) < line * 2.5
        }
        guard !fits(name) else { return name }
        let characters = Array(name)
        func cut(_ keep: Int) -> String {
            let tail = max(1, keep / 2)
            return String(characters.prefix(keep - tail)) + "…" + String(characters.suffix(tail))
        }
        // The most characters that still fit two lines.
        var low = 2, high = max(2, characters.count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(cut(mid)) { low = mid } else { high = mid - 1 }
        }
        return cut(low)
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: (bounds.width - Self.iconSize) / 2, y: 8, width: Self.iconSize, height: Self.iconSize)
        name.frame = CGRect(x: 2, y: 60, width: bounds.width - 4, height: 32)
        close.frame = CGRect(x: bounds.width - 20, y: 4, width: 16, height: 16)
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The × takes its own clicks (with a little slack, it's small); everything
    /// else on the tile comes here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !close.isHidden, close.frame.insetBy(dx: -4, dy: -4).contains(local) { return close }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(icon.frame, contents: icon.image)
        NotchTrayPane.isDraggingOut = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downPoint = nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // MARK: Dragging out

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NotchTrayPane.isDraggingOut = false
        hovered = false
    }
}

/// The tile's small round ×.
final class NotchTrayCloseButton: NSView {
    var onClick: (() -> Void)?
    private let mark = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet { layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.34 : 0.18).cgColor }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        mark.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
        mark.imageScaling = .scaleNone
        mark.unregisterDraggedTypes()
        addSubview(mark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        mark.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.insetBy(dx: -4, dy: -4).contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// A plain text button for the tray page ("Clear"): a label that brightens
/// under the pointer and takes the first click.
final class NotchTrayTextButton: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet { label.textColor = NSColor(white: 1, alpha: hovered ? 0.9 : 0.55) }
    }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = NSColor(white: 1, alpha: 0.55)
        label.sizeToFit()
        // A little slack around the words: the click target is bigger than them.
        frame.size = CGSize(width: label.frame.width + 12, height: max(20, label.frame.height + 4))
        label.frame.origin = CGPoint(x: 6, y: ((frame.height - label.frame.height) / 2).rounded())
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
