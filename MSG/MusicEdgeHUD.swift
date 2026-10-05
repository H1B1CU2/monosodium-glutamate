import AppKit
import QuartzCore

/// Now-playing controls at the bottom screen edge, each glyph right above its
/// key — previous over F7, play/pause over F8, next over F9 — shown when one
/// of those keys is pressed, like the brightness and volume HUDs. The pressed
/// glyph lights up; the play/pause glyph follows the real playback state.
final class MusicEdgeHUD {
    static let shared = MusicEdgeHUD()

    private static let linger: TimeInterval = 2.0

    private var window: NSWindow?
    private var view: MusicEdgeHUDView?
    private var hideWork: DispatchWorkItem?
    private var sampleTimer: Timer?
    private var isShowing = false
    private weak var monitor: MusicMonitor?
    private let adapter = MediaRemoteAdapter()

    struct State {
        var title: String?
        var artist: String?
        var source: String?
        var art: NSImage?
        var appIcon: NSImage?
        var playing: Bool
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?

        var progress: Double? {
            guard let duration, duration > 0, let elapsed else { return nil }
            let r = rate ?? (playing ? 1.0 : 0.0)
            let dt = timestamp.map { max(0, Date().timeIntervalSince1970 - $0) } ?? 0
            let current = elapsed + dt * r
            return max(0.0, min(1.0, current / duration))
        }
    }
    private var lastState: State?
    /// Every Now Playing read, for the Edge Keys strip's media key.
    var onState: ((State) -> Void)?
    /// Keep reading while the strip's media key shows, as while the pop-up does.
    var keepsFresh = false
    private var stripPollingRelease: DispatchWorkItem?
    private var holdsPolling = false

    private var isEnabled: Bool { EdgeKeys.popupsActive }

    private init() {
        // A window kept across a display change can end up where it never
        // shows again; build a fresh one on the next key press.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.discard()
        }
    }

    /// Wires playback changes in, so the play/pause glyph and the title follow
    /// what the key actually did.
    func attach(to monitor: MusicMonitor) {
        self.monitor = monitor
        monitor.addObserver { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func show(action: MediaKeyAction) {
        // The strip's own keys turn into the player; no pop-up then.
        if EdgeKeyStrip.shared.isVisible {
            trackTransport(action)
            return
        }
        guard isEnabled, let screen = NSScreen.screens.first(where: \.isBuiltin) else { return }
        hideWork?.cancel()

        let unit = screen.frame.width * FunctionRow.unit
        // Over the keys that actually do media — reassigned on the strip, or F7–F9.
        let keys = EdgeKeyStrip.shared.mediaPopupKeys() ?? [7, 8, 9]
        let centers = keys.map { screen.frame.width * FunctionRow.center(of: $0) }
        let size = MusicEdgeHUDView.size(unit: unit)
        let midX = screen.frame.minX + centers[1]
        // Kept on screen when the keys sit near an end of the row.
        let x = min(max(midX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        let frame = CGRect(x: x.rounded(), y: screen.frame.minY,
                           width: size.width, height: size.height)
        // Glyph centres relative to the window.
        let glyphXs = centers.map { screen.frame.minX + $0 - frame.minX }
        // The bar spans across the 3 keycaps, inset by 10 pt.
        let trackWidth = max(20, (centers[2] - centers[0] + screen.frame.width * FunctionRow.face).rounded() - 10)

        if view?.glyphXs != glyphXs || view?.trackWidth != trackWidth || window?.frame.size != frame.size {
            discard()
        }
        let appearing = !isShowing || window == nil
        if window == nil {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let view = MusicEdgeHUDView(size: size, glyphXs: glyphXs, trackWidth: trackWidth)
            window.contentView = view
            self.window = window
            self.view = view
        }
        if window?.frame != frame { window?.setFrame(frame, display: false) }
        window?.orderFrontRegardless()
        isShowing = true
        if appearing { adaptToBackdrop(animated: false) }

        seedFromMonitor()

        let currentlyPlaying = lastState?.playing ?? (monitor?.isPlaying ?? false)
        let expectedPlaying = action == .playPause ? !currentlyPlaying : currentlyPlaying
        if action == .playPause {
            lastState?.playing = expectedPlaying
            // The player takes a moment to report the new state; until it
            // does (or ~1.2 s passes), a read of the old one is not believed.
            playPauseExpectation = (expectedPlaying, CACurrentMediaTime() + 1.2)
        }
        let current = lastState
        // Press first: it resets the glyphs, and would cut short the
        // play/pause morph that `update` starts.
        view?.press(action, appearing: appearing)
        view?.update(title: current?.title, artist: current?.artist, source: current?.source,
                     art: current?.art, appIcon: current?.appIcon,
                     progress: current?.progress,
                     playing: expectedPlaying, placeholder: current != nil,
                     appearing: appearing)

        // Query MediaRemote directly so any System Now Playing source (browsers, YouTube, Spotify, etc.) updates instantly
        queryNowPlaying(expectedPlaying: action == .playPause ? expectedPlaying : nil)

        if !holdsPolling, let monitor {
            holdsPolling = true
            monitor.retainPolling()
            monitor.pokeNow()
        }

        if sampleTimer == nil {
            sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.adaptToBackdrop(animated: true)
                self.tickProgress()
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    /// A fresh read for the strip's player, without a key press.
    func refreshForStrip() {
        seedFromMonitor()
        if let lastState { onState?(lastState) }
        queryNowPlaying()
    }

    /// Before the first read, what the music monitor already knows.
    private func seedFromMonitor() {
        guard lastState == nil, let monitor else { return }
        let monTitle = monitor.currentTitle
        let monArtist = monitor.currentArtist
        let monSource = monitor.currentSource
        var monIcon: NSImage? = nil
        if let bid = monitor.currentSourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            monIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        if monTitle != nil || monSource != nil {
            lastState = State(title: monTitle, artist: monArtist, source: monSource,
                              art: monitor.albumArt, appIcon: monIcon, playing: monitor.isPlaying,
                              duration: monitor.currentDuration, elapsed: monitor.currentElapsed,
                              rate: monitor.currentRate, timestamp: monitor.currentTimestamp)
        }
    }

    /// Strip mode: no pop-up, only the state behind the strip's media key —
    /// the same reads, the same play/pause expectation.
    private func trackTransport(_ action: MediaKeyAction) {
        seedFromMonitor()
        let currentlyPlaying = lastState?.playing ?? (monitor?.isPlaying ?? false)
        let expectedPlaying = action == .playPause ? !currentlyPlaying : currentlyPlaying
        if action == .playPause {
            lastState?.playing = expectedPlaying
            playPauseExpectation = (expectedPlaying, CACurrentMediaTime() + 1.2)
        }
        if let lastState { onState?(lastState) }
        queryNowPlaying(expectedPlaying: action == .playPause ? expectedPlaying : nil)
        // Read often for a while, as the pop-up does while it shows.
        if !holdsPolling, let monitor {
            holdsPolling = true
            monitor.retainPolling()
            monitor.pokeNow()
        }
        stripPollingRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowing else { return }
            self.releasePolling()
        }
        stripPollingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func queryNowPlaying(expectedPlaying: Bool? = nil) {
        adapter.query { [weak self] np in
            guard let self else { return }
            var title = np?.title
            var artist = np?.artist
            var source: String? = nil
            var appIcon: NSImage? = nil
            var art = np?.art

            if let pid = np?.pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                source = app.localizedName
                appIcon = app.icon
            }

            if title == nil && artist == nil, let monitor = self.monitor, (monitor.currentTitle != nil || monitor.currentSource != nil) {
                title = monitor.currentTitle
                artist = monitor.currentArtist
                if source == nil { source = monitor.currentSource }
                if art == nil { art = monitor.albumArt }
                if appIcon == nil, let bid = monitor.currentSourceBundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    appIcon = NSWorkspace.shared.icon(forFile: url.path)
                }
            }

            // A read right after play/pause often carries no artwork yet
            // (Apple Music sends it a moment later); for the same track, keep
            // the cover already showing instead of flicking to the app icon.
            if art == nil, let last = self.lastState, last.title == title, last.artist == artist {
                art = last.art
            }
            var playing = expectedPlaying ?? (np?.playing ?? (self.monitor?.isPlaying ?? false))
            if let expectation = self.playPauseExpectation {
                if playing == expectation.playing || CACurrentMediaTime() > expectation.until {
                    self.playPauseExpectation = nil
                } else {
                    playing = expectation.playing
                }
            }
            let duration = np?.duration ?? self.monitor?.currentDuration
            let elapsed = np?.elapsed ?? self.monitor?.currentElapsed
            let rate = np?.rate ?? self.monitor?.currentRate
            let timestamp = np?.timestamp ?? self.monitor?.currentTimestamp

            let state = State(title: title, artist: artist, source: source,
                              art: art, appIcon: appIcon, playing: playing,
                              duration: duration, elapsed: elapsed,
                              rate: rate, timestamp: timestamp)
            self.lastState = state
            self.onState?(state)

            if self.isShowing {
                self.view?.update(title: title, artist: artist, source: source,
                                  art: art, appIcon: appIcon,
                                  progress: state.progress,
                                  playing: playing, placeholder: true)
            }

            if art == nil, let artURL = np?.artURL {
                URLSession.shared.dataTask(with: artURL) { [weak self] data, _, _ in
                    guard let self, let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        if self.lastState?.title == title {
                            self.lastState?.art = img
                            if let state = self.lastState { self.onState?(state) }
                            if self.isShowing {
                                self.view?.update(title: title, artist: artist, source: source,
                                                  art: img, appIcon: appIcon,
                                                  progress: self.lastState?.progress,
                                                  playing: playing, placeholder: true)
                            }
                        }
                    }
                }.resume()
            }
        }
    }

    private func tickProgress() {
        guard isShowing, let state = lastState, state.playing else { return }
        view?.updateProgress(state.progress, animated: true)
    }

    /// What the last play/pause press should lead to, and until when a
    /// contrary (stale) read is ignored.
    private var playPauseExpectation: (playing: Bool, until: CFTimeInterval)?

    private func refresh() {
        guard isShowing || keepsFresh else { return }
        queryNowPlaying()
    }

    private func adaptToBackdrop(animated: Bool) {
        guard let window, let view,
              let luminance = BackdropLuminance.sample(appKitRect: window.frame,
                                                       below: CGWindowID(window.windowNumber)) else { return }
        let style = EdgeHUDStyle.next(for: luminance, from: view.style)
        if style != view.style || !animated { view.apply(style, animated: animated) }
    }

    private func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        isShowing = false
        guard let view else { return }
        view.playHide()
        DispatchQueue.main.asyncAfter(deadline: .now() + MusicEdgeHUDView.hideDuration) { [weak self] in
            // A key pressed during the fade brought it back.
            guard let self, !self.isShowing else { return }
            self.window?.orderOut(nil)
            self.releasePolling()
        }
    }

    private func releasePolling() {
        guard holdsPolling else { return }
        holdsPolling = false
        monitor?.releasePolling()
    }

    private func discard() {
        hideWork?.cancel()
        hideWork = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        window?.orderOut(nil)
        window = nil
        view = nil
        isShowing = false
        releasePolling()
    }
}

private final class MusicEdgeHUDView: NSView {
    static let hideDuration: TimeInterval = 0.28

    /// Three keys wide plus a wide feathered margin, and taller than the
    /// other HUDs: the title line sits above the glyphs, and the shading only
    /// holds it back well inside the stronger middle of its falloff.
    static func size(unit: CGFloat) -> CGSize {
        CGSize(width: (unit * 3 + 220).rounded(), height: 88)
    }

    let glyphXs: [CGFloat]
    let trackWidth: CGFloat
    private var trackSize: CGSize { CGSize(width: trackWidth, height: 3.5) }
    private static let trackInset: CGFloat = 5
    private static let glyphSide: CGFloat = 20
    private static let glyphY: CGFloat = 16
    private static let dimmed: CGFloat = 0.42

    private(set) var style: EdgeHUDStyle = .dark(luminance: 0.5)

    private let scrim = EdgeScrimView()
    private let content = NSView()
    private let track = CALayer()
    private let fill = CALayer()
    private let glow = CALayer()
    private let glyphs: [NSImageView]
    private let art = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var playing = false
    private var pressed: MediaKeyAction?

    init(size: CGSize, glyphXs: [CGFloat], trackWidth: CGFloat) {
        self.glyphXs = glyphXs
        self.trackWidth = trackWidth
        self.glyphs = (0..<3).map { _ in NSImageView() }
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        scrim.frame = bounds
        addSubview(scrim)

        content.frame = bounds
        content.wantsLayer = true
        addSubview(content)
        guard let root = content.layer else { return }

        let trackX = (glyphXs[1] - trackSize.width / 2).rounded()
        let trackFrame = CGRect(x: trackX, y: Self.trackInset,
                                width: trackSize.width, height: trackSize.height)

        track.frame = trackFrame
        track.cornerRadius = trackSize.height / 2
        track.backgroundColor = style.track.cgColor
        track.masksToBounds = true
        track.opacity = 0
        root.addSublayer(track)

        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackSize.height)
        fill.backgroundColor = style.glyph.cgColor
        track.addSublayer(fill)

        glow.frame = trackFrame
        glow.cornerRadius = trackSize.height / 2
        glow.backgroundColor = NSColor.clear.cgColor
        glow.shadowPath = CGPath(roundedRect: glow.bounds, cornerWidth: glow.cornerRadius,
                                 cornerHeight: glow.cornerRadius, transform: nil)
        glow.shadowColor = style.glow.cgColor
        glow.shadowOpacity = Float(style.glowOpacity)
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        glow.opacity = 0
        root.insertSublayer(glow, below: track)

        for (i, glyph) in glyphs.enumerated() {
            glyph.frame = CGRect(x: (glyphXs[i] - Self.glyphSide / 2).rounded(), y: Self.glyphY,
                                 width: Self.glyphSide, height: Self.glyphSide)
            glyph.imageScaling = .scaleProportionallyDown
            glyph.wantsLayer = true
            addSubview(glyph)
        }

        art.frame = CGRect(x: 0, y: 44, width: 18, height: 18)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 4
        art.layer?.cornerCurve = .continuous
        art.layer?.masksToBounds = true
        addSubview(art)

        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        title.maximumNumberOfLines = 1
        addSubview(title)

        subviews.forEach { if $0 !== scrim && $0 !== content { $0.alphaValue = 0 } }
        apply(style, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `placeholder` false leaves the line blank rather than "Not Playing"
    /// while the first read is still on its way.
    func update(title titleText: String?, artist: String?, source sourceName: String?,
                art artImage: NSImage?, appIcon: NSImage?,
                progress: Double?,
                playing: Bool, placeholder: Bool,
                appearing: Bool = false) {
        self.playing = playing
        let parts = [titleText, artist].compactMap { $0?.isEmpty == false ? $0 : nil }
        if !parts.isEmpty {
            title.stringValue = parts.joined(separator: " — ")
        } else if let sourceName, !sourceName.isEmpty {
            title.stringValue = sourceName
        } else {
            title.stringValue = placeholder ? "Not Playing" : ""
        }

        let hasContent = !parts.isEmpty || (sourceName?.isEmpty == false)
        if hasContent {
            art.image = artImage ?? appIcon
        } else {
            art.image = nil
        }
        layoutTitle()
        renderGlyphs()
        updateProgress(progress, appearing: appearing, animated: !appearing)
    }

    func updateProgress(_ progress: Double?, appearing: Bool = false, animated: Bool = true) {
        let hasContent = (art.image != nil || !title.stringValue.isEmpty) && title.stringValue != "Not Playing"
        guard let progress, hasContent else {
            track.opacity = 0
            glow.opacity = 0
            return
        }
        let p = max(0.0, min(1.0, CGFloat(progress)))
        let fillWidth = (trackSize.width * p).rounded()
        CATransaction.begin()
        CATransaction.setAnimationDuration(appearing ? 0 : (animated ? 0.35 : 0.14))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: (animated && !appearing) ? .linear : .easeOut))
        fill.bounds.size.width = fillWidth
        CATransaction.commit()

        if appearing {
            for layer in [track, glow] {
                let fromOpacity = (layer.animation(forKey: "hide") != nil)
                    ? (layer.presentation()?.opacity ?? 0)
                    : 0
                layer.removeAllAnimations()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = fromOpacity
                fade.toValue = 1
                fade.duration = 0.3
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fade")
                layer.opacity = 1
            }
        } else {
            track.opacity = 1
            glow.opacity = 1
        }
    }

    /// The pressed glyph lights up and bounces; the others stay dimmed.
    func press(_ action: MediaKeyAction, appearing: Bool) {
        pressed = action
        scrim.fade(to: 1, duration: appearing ? 0.3 : 0)
        let index: Int
        switch action {
        case .previous: index = 0
        case .playPause: index = 1
        case .next: index = 2
        }
        for (i, glyph) in glyphs.enumerated() {
            glyph.layer?.removeAllAnimations()
            glyph.alphaValue = i == index ? 1 : Self.dimmed
        }
        [art, title].forEach { $0.alphaValue = 1 }
        renderGlyphs()

        // Play/pause animates by morphing ⏸↔▶; a bounce on top fought it.
        if #available(macOS 14.0, *), action != .playPause {
            glyphs[index].addSymbolEffect(.bounce.down, options: .nonRepeating)
        }

        guard appearing else { return }
        for view in [title, art] + glyphs {
            guard let layer = view.layer else { continue }
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -5
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = layer.opacity
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 0.3
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "appear")
        }
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
        glow.shadowOpacity = Float(style.glowOpacity)
        CATransaction.commit()

        title.textColor = style.glyph
        let shadow = NSShadow()
        shadow.shadowColor = style.glow.withAlphaComponent(CGFloat(style.glowOpacity))
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = .zero
        ([title] + glyphs).forEach { $0.shadow = shadow }
        renderGlyphs()
    }

    func playHide() {
        scrim.fade(to: 0, duration: Self.hideDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ([title, art] + glyphs).forEach { $0.animator().alphaValue = 0 }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = track.presentation()?.opacity ?? track.opacity
        fade.toValue = 0
        fade.duration = Self.hideDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        track.add(fade, forKey: "hide")
        glow.add(fade, forKey: "hide")
        track.opacity = 0
        glow.opacity = 0
    }

    private func renderGlyphs() {
        let names = ["backward.fill", playing ? "pause.fill" : "play.fill", "forward.fill"]
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [style.glyph]))
        let colorChanged = renderedColor != style.glyph
        renderedColor = style.glyph
        for (i, (glyph, name)) in zip(glyphs, names).enumerated() {
            // Refreshes (title, artwork, backdrop samples) land here often;
            // only a real symbol change may morph, or it replays every time.
            let changed = renderedNames.count == glyphs.count ? renderedNames[i] != name : true
            guard changed || colorChanged else { continue }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            if #available(macOS 14.0, *), let image, changed, !colorChanged, glyph.image != nil {
                glyph.setSymbolImage(image, contentTransition: .replace.downUp)
            } else {
                glyph.image = image
            }
        }
        renderedNames = names
    }

    private var renderedNames: [String] = []
    private var renderedColor: NSColor?

    /// Title centred over the play/pause key, with the artwork beside it.
    private func layoutTitle() {
        let hasArt = art.image != nil
        // Kept to the three keys' span (plus a little) so a long title stays
        // over the strong part of the shading instead of its fading sides.
        let maxWidth = bounds.width - 220 + 50
        // The label's cell insets its text a little; without the slack even
        // "Not Playing" truncated.
        let textWidth = min(maxWidth - (hasArt ? 24 : 0), ceil(title.intrinsicContentSize.width) + 6)
        let total = textWidth + (hasArt ? 24 : 0)
        let startX = (glyphXs[1] - total / 2).rounded()
        art.isHidden = !hasArt
        art.frame.origin.x = startX
        title.frame = CGRect(x: startX + (hasArt ? 24 : 0), y: 45, width: textWidth, height: 16)
    }
}
