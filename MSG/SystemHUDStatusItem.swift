import AppKit

final class SystemHUDStatusItem {
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private let renderer: IndicatorRenderer

    private var active = false
    private var kind: SystemHUDKind = .volume
    private var muted = false
    private var audioOutputKind: AudioOutputKind?
    private var value: CGFloat = 0
    private var target: CGFloat = 0
    private var fillTimer: Timer?
    private var expireTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.renderer = IndicatorRenderer(settings: settings, statusItem: statusItem)
        statusItem.isVisible = false
        statusItem.button?.imagePosition = .imageOnly
    }

    func show(kind: SystemHUDKind, value rawValue: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?) {
        let nextValue = max(0, min(1, rawValue))
        let wasActive = active
        self.kind = kind
        self.muted = muted
        self.audioOutputKind = audioOutputKind
        self.target = nextValue
        statusItem.isVisible = true

        if !wasActive {
            active = true
            value = nextValue
            render()
            if let button = statusItem.button {
                button.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    button.animator().alphaValue = 1
                }
            }
        } else {
            animateFill()
        }
        resetExpire()
    }

    func remove() {
        fillTimer?.invalidate()
        expireTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func animateFill() {
        fillTimer?.invalidate()
        let start = value
        let delta = target - start
        guard abs(delta) > 0.0001 else {
            value = target
            render()
            return
        }

        let startTime = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.18
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let progress = max(0, min(1, CGFloat(elapsed / duration)))
            self.value = start + delta * Easing.outQuart(progress)
            self.render()
            if progress >= 1 {
                timer.invalidate()
                self.fillTimer = nil
                self.value = self.target
                self.render()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        fillTimer = timer
    }

    private func render() {
        guard active, let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString()
        let frame = renderer.makeSystemHUDFrame(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
        button.image = frame
        statusItem.length = frame.size.width + 4
    }

    private func resetExpire() {
        expireTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.current.add(timer, forMode: .common)
        expireTimer = timer
    }

    private func dismiss() {
        expireTimer?.invalidate()
        expireTimer = nil
        fillTimer?.invalidate()
        fillTimer = nil
        guard let button = statusItem.button else {
            active = false
            statusItem.isVisible = false
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.active = false
            self.statusItem.isVisible = false
            button.alphaValue = 1
        })
    }
}
