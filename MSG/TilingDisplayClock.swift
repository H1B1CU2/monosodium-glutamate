import AppKit
import QuartzCore

/// One clock per animated display, alive only while there is visible motion.
/// AppKit supplies ProMotion timing; AX delivery remains latest-only downstream.
final class TilingDisplayClock: NSObject {
    private var invalidateNative: (() -> Void)?
    private var fallback: Timer?
    private let screen: NSScreen
    private let update: () -> Void

    static func maximumRate(for screen: NSScreen?) -> Int {
        let hardware = max(30, screen?.maximumFramesPerSecond ?? 60)
        let process = ProcessInfo.processInfo
        let cap: Int
        switch process.thermalState {
        case .critical: cap = 30
        case .serious: cap = 60
        default: cap = process.isLowPowerModeEnabled ? 60 : 120
        }
        return min(hardware, cap)
    }

    static func interval(for screen: NSScreen?) -> TimeInterval {
        1.0 / Double(maximumRate(for: screen))
    }

    init(screen: NSScreen, update: @escaping () -> Void) {
        self.screen = screen
        self.update = update
        super.init()
        if #available(macOS 14.0, *) {
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            configure(link)
            invalidateNative = { link.invalidate() }
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: Self.interval(for: screen), repeats: true) { [weak self] _ in
                self?.update()
            }
            timer.tolerance = Self.interval(for: screen) * 0.1
            fallback = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @available(macOS 14.0, *)
    private func configure(_ link: CADisplayLink) {
        let rate = Float(Self.maximumRate(for: screen))
        if link.preferredFrameRateRange.maximum != rate {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
        }
    }

    @available(macOS 14.0, *)
    @objc private func tick(_ link: CADisplayLink) {
        configure(link)
        update()
    }

    func invalidate() {
        invalidateNative?()
        invalidateNative = nil
        fallback?.invalidate()
        fallback = nil
    }
}
