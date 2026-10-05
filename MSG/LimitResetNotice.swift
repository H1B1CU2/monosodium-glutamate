import AppKit

// MARK: - AI limit resets in the notch
//
// When a usage window TokenBar tracks comes round (Claude's and ChatGPT's
// 5-hour and weekly limits, Antigravity's Gemini and Claude & GPT ones), the
// notch says so: "Claude limit reset". It's timed from the reset times in
// TokenBar's snapshot, with one timer for the next one due, so it shows on the
// minute rather than at TokenBar's next refresh. Only a window that had
// something used is announced. One that came round while the screen was locked
// or the Mac asleep is announced on return, if that's within the hour.

final class LimitResetNotice {
    static let shared = LimitResetNotice()

    private struct Limit {
        /// Provider and window, e.g. "claude.session".
        let key: String
        let provider: AIProvider
        let window: String
        let used: Double
        let resetAt: Double
    }

    /// Windows with something used, waiting for their reset.
    private var armed: [String: Limit] = [:]
    /// "key@minute" of each reset already announced.
    private var announced: Set<String> = []
    /// Announced but not yet shown (no notch on screen); with their reset time.
    private var pending: [(notice: NotchHUDView.Notice, resetAt: Double)] = []
    private var timer: Timer?
    private var started = false
    /// Later than this after the reset, it's old news.
    private static let lateLimit: TimeInterval = 3600

    private init() {}

    private var enabled: Bool { AppSettings.shared.notchLimitResetNotice }

    func start() {
        guard !started else { return }
        started = true
        AIUsageFeed.shared.addObserver { [weak self] snapshot in self?.update(snapshot) }
        AIUsageFeed.shared.start()
        // Locked or asleep at the time: the timer fires late, if at all.
        PresentationState.shared.addObserver { [weak self] in self?.catchUp() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.catchUp()
        }
        // For trying the card: post `H1D3S1GN.MSG.debug.limitReset` with a provider
        // ("claude", "codex", "antigravity") as its object.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("H1D3S1GN.MSG.debug.limitReset"),
                                                            object: nil, queue: .main) { [weak self] note in
            let provider = (note.object as? String).flatMap(AIProvider.init(rawValue:)) ?? .claude
            let limit = Limit(key: "debug", provider: provider, window: "5-hour window", used: 42,
                              resetAt: Date().timeIntervalSince1970)
            self?.pending.append((Self.notice(for: limit), limit.resetAt))
            self?.flush()
        }
        update(AIUsageFeed.shared.snapshot)
    }

    /// The setting flipped. Main thread.
    func settingChanged() {
        if !enabled { pending.removeAll() }
        schedule()
    }

    private func update(_ snapshot: TokenBarSnapshot?) {
        let now = Date().timeIntervalSince1970
        // Anything whose time came while nobody was looking goes first, before
        // the new numbers replace it.
        collectDue(now: now)
        var next: [String: Limit] = [:]
        for limit in Self.limits(in: snapshot) where limit.used >= 1 && limit.resetAt > now {
            next[limit.key] = limit
        }
        armed = next
        schedule()
    }

    private func catchUp() {
        collectDue(now: Date().timeIntervalSince1970)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled, let due = armed.values.map(\.resetAt).min() else { return }
        let timer = Timer(fire: Date(timeIntervalSince1970: due + 1), interval: 0, repeats: false) { [weak self] _ in
            self?.catchUp()
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func collectDue(now: Double) {
        for (key, limit) in armed where limit.resetAt <= now {
            armed[key] = nil
            let id = "\(key)@\(Int(limit.resetAt / 60))"
            guard enabled, now - limit.resetAt < Self.lateLimit, announced.insert(id).inserted else { continue }
            pending.append((Self.notice(for: limit), limit.resetAt))
        }
        flush()
    }

    /// Shows what's waiting, oldest first, while the notch takes them.
    private func flush() {
        let now = Date().timeIntervalSince1970
        pending.removeAll { now - $0.resetAt >= Self.lateLimit }
        while let first = pending.first, NotchHUD.shared.showNotice(first.notice) {
            pending.removeFirst()
        }
    }

    private static func notice(for limit: Limit) -> NotchHUDView.Notice {
        let name = limit.provider == .codex ? "ChatGPT" : AgentActivityCardView.name(for: limit.provider)
        return .init(provider: limit.provider, title: "\(name) limit reset",
                     detail: "\(limit.window) · was \(Int(limit.used.rounded()))% used", value: "100%")
    }

    private static func limits(in snapshot: TokenBarSnapshot?) -> [Limit] {
        guard let snapshot else { return [] }
        var limits: [Limit] = []
        func add(_ provider: AIProvider, _ id: String, _ window: String, _ used: Double?, _ resetAt: Double?) {
            guard let used, let resetAt, used.isFinite, resetAt.isFinite else { return }
            limits.append(Limit(key: "\(provider.rawValue).\(id)", provider: provider, window: window,
                                used: used, resetAt: resetAt))
        }
        for (provider, session) in [(AIProvider.claude, snapshot.claude), (.codex, snapshot.codex)] {
            guard let session, session.enabled != false, session.available == true else { continue }
            add(provider, "session", "5-hour window", session.sessionPercent, session.sessionResetAt)
            add(provider, "week", "Weekly limit", session.weekPercent, session.weekResetAt)
        }
        if let ag = snapshot.antigravity, ag.enabled != false, ag.available == true {
            add(.antigravity, "gemini.session", "Gemini 5-hour window", ag.geminiSessionPercent, ag.geminiSessionResetAt)
            add(.antigravity, "gemini.week", "Gemini weekly limit", ag.geminiPercent, ag.geminiResetAt)
            add(.antigravity, "claudeGpt.session", "Claude & GPT 5-hour window",
                ag.claudeGptSessionPercent, ag.claudeGptSessionResetAt)
            add(.antigravity, "claudeGpt.week", "Claude & GPT weekly limit", ag.claudeGptPercent, ag.claudeGptResetAt)
        }
        return limits
    }
}
