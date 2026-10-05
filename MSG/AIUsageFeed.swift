import AppKit

// MARK: - Snapshot

/// The four providers TokenBar tracks, in the order the esc-spot widget pages them.
enum AIProvider: String, CaseIterable {
    case claude, codex, antigravity, deepseek
}

/// The countdown wording shared by the Esc widget and lock-screen quota card.
enum UsageResetCountdown {
    static func text(until epoch: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let seconds = Int(ceil(date.timeIntervalSince(now)))
        guard seconds > 0 else { return "ready" }
        if seconds >= 24 * 3600 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "E HH:mm"
            return formatter.string(from: date)
        }
        if seconds >= 3600 {
            let minutes = Int(ceil(Double(seconds) / 60))
            return minutes < 60 ? "\(minutes) min left" : "\(minutes / 60) hr \(minutes % 60) min left"
        }
        if seconds >= 60 { return "\(seconds / 60) min \(seconds % 60) sec" }
        return "\(seconds) sec"
    }
}

/// What TokenBar writes to `widget-snapshot.json`. Every field is optional and a field of the
/// wrong type reads as missing, so a partial or newer file never fails the whole read. All
/// percents are used, 0–100; dates are Unix epoch seconds.
struct TokenBarSnapshot: Decodable {
    struct WorkingSession: Decodable, Equatable {
        struct Destination: Decodable, Equatable {
            var url: String?
            var bundleID: String?
        }
        var id: String?
        var title: String?
        var since: Double?
        var activity: String?
        var completedSteps: Int?
        var totalSteps: Int?
        /// What the user asked for in this turn. Absent from older TokenBar builds.
        var prompt: String?
        var destination: Destination?

        init(id: String? = nil, title: String? = nil, since: Double? = nil,
             activity: String? = nil, completedSteps: Int? = nil, totalSteps: Int? = nil, prompt: String? = nil,
             destination: Destination? = nil) {
            self.id = id; self.title = title; self.since = since; self.activity = activity
            self.completedSteps = completedSteps; self.totalSteps = totalSteps; self.prompt = prompt
            self.destination = destination
        }

        private enum Keys: String, CodingKey { case id, title, since, activity, completedSteps, totalSteps, prompt, destination }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            since = try? c.decodeIfPresent(Double.self, forKey: .since)
            activity = try? c.decodeIfPresent(String.self, forKey: .activity)
            completedSteps = try? c.decodeIfPresent(Int.self, forKey: .completedSteps)
            totalSteps = try? c.decodeIfPresent(Int.self, forKey: .totalSteps)
            prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
            destination = try? c.decodeIfPresent(Destination.self, forKey: .destination)
        }
    }

    struct ExhaustedPrimaryLimit: Equatable {
        let provider: AIProvider
        let resetAt: Double
    }

    struct Session: Decodable {
        var enabled: Bool?
        var available: Bool?
        var sessionPercent: Double?
        var sessionResetAt: Double?
        var weekPercent: Double?
        var weekResetAt: Double?
        var active: Bool?
        var activeTitle: String?
        /// Claude only: TokenBar's login expired and needs the user;
        /// `AIUsageFeed.requestClaudeSignIn()` opens TokenBar's sign-in window.
        var signInRequired: Bool?

        private enum Keys: String, CodingKey {
            case enabled, available, sessionPercent, sessionResetAt, weekPercent, weekResetAt, active, activeTitle
            case signInRequired
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            available = try? c.decodeIfPresent(Bool.self, forKey: .available)
            sessionPercent = try? c.decodeIfPresent(Double.self, forKey: .sessionPercent)
            sessionResetAt = try? c.decodeIfPresent(Double.self, forKey: .sessionResetAt)
            weekPercent = try? c.decodeIfPresent(Double.self, forKey: .weekPercent)
            weekResetAt = try? c.decodeIfPresent(Double.self, forKey: .weekResetAt)
            active = try? c.decodeIfPresent(Bool.self, forKey: .active)
            activeTitle = try? c.decodeIfPresent(String.self, forKey: .activeTitle)
            signInRequired = try? c.decodeIfPresent(Bool.self, forKey: .signInRequired)
        }
    }

    struct Antigravity: Decodable {
        var enabled: Bool?
        var available: Bool?
        var geminiPercent: Double?
        var geminiResetAt: Double?
        var claudeGptPercent: Double?
        var claudeGptResetAt: Double?
        /// The 5-hour windows (the fields above are weekly). Absent from older TokenBar builds.
        var geminiSessionPercent: Double?
        var geminiSessionResetAt: Double?
        var claudeGptSessionPercent: Double?
        var claudeGptSessionResetAt: Double?
        var active: Bool?
        var activeTitle: String?

        private enum Keys: String, CodingKey {
            case enabled, available, geminiPercent, geminiResetAt, claudeGptPercent, claudeGptResetAt, active, activeTitle
            case geminiSessionPercent, geminiSessionResetAt, claudeGptSessionPercent, claudeGptSessionResetAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            available = try? c.decodeIfPresent(Bool.self, forKey: .available)
            geminiPercent = try? c.decodeIfPresent(Double.self, forKey: .geminiPercent)
            geminiResetAt = try? c.decodeIfPresent(Double.self, forKey: .geminiResetAt)
            claudeGptPercent = try? c.decodeIfPresent(Double.self, forKey: .claudeGptPercent)
            claudeGptResetAt = try? c.decodeIfPresent(Double.self, forKey: .claudeGptResetAt)
            geminiSessionPercent = try? c.decodeIfPresent(Double.self, forKey: .geminiSessionPercent)
            geminiSessionResetAt = try? c.decodeIfPresent(Double.self, forKey: .geminiSessionResetAt)
            claudeGptSessionPercent = try? c.decodeIfPresent(Double.self, forKey: .claudeGptSessionPercent)
            claudeGptSessionResetAt = try? c.decodeIfPresent(Double.self, forKey: .claudeGptSessionResetAt)
            active = try? c.decodeIfPresent(Bool.self, forKey: .active)
            activeTitle = try? c.decodeIfPresent(String.self, forKey: .activeTitle)
        }
    }

    struct DeepSeek: Decodable {
        var enabled: Bool?
        var available: Bool?
        var balance: Double?
        var currency: String?
        var balanceTHB: Double?

        private enum Keys: String, CodingKey { case enabled, available, balance, currency, balanceTHB }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            available = try? c.decodeIfPresent(Bool.self, forKey: .available)
            balance = try? c.decodeIfPresent(Double.self, forKey: .balance)
            currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            balanceTHB = try? c.decodeIfPresent(Double.self, forKey: .balanceTHB)
        }
    }

    /// The tasks TokenBar's local scanner sees running, per provider, and when
    /// the current run began. It comes from TokenBar's local task scan and
    /// carries its own heartbeat, independently of quota polling. Absent from
    /// TokenBar builds that predate it.
    struct Processing: Decodable {
        var claude: Int?
        var codex: Int?
        var antigravity: Int?
        var since: Double?
        var updatedAt: Double?
        /// The working threads' names as each app shows them ("claude", "codex",
        /// "antigravity"), main sessions first. Absent from older TokenBar builds.
        var titles: [String: [String]]?
        var sessions: [String: [WorkingSession]]?

        private enum Keys: String, CodingKey { case claude, codex, antigravity, since, updatedAt, titles, sessions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            claude = try? c.decodeIfPresent(Int.self, forKey: .claude)
            codex = try? c.decodeIfPresent(Int.self, forKey: .codex)
            antigravity = try? c.decodeIfPresent(Int.self, forKey: .antigravity)
            since = try? c.decodeIfPresent(Double.self, forKey: .since)
            updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
            titles = try? c.decodeIfPresent([String: [String]].self, forKey: .titles)
            sessions = try? c.decodeIfPresent([String: [WorkingSession]].self, forKey: .sessions)
        }

        func titles(_ provider: AIProvider) -> [String] {
            titles?[provider.rawValue] ?? []
        }

        func count(_ provider: AIProvider) -> Int {
            switch provider {
            case .claude:      return max(0, claude ?? 0)
            case .codex:       return max(0, codex ?? 0)
            case .antigravity: return max(0, antigravity ?? 0)
            case .deepseek:    return 0
            }
        }
    }

    struct Usage: Decodable {
        var firstDayOfWeek: String?
        var histories: [String: [String: Double]]?
        var deepseekCurrency: String?
        var billingPeriod: String?
        var billingDetail: String?
        var billingTransitionAt: Double?
        var antigravityStatus: String?

        private enum Keys: String, CodingKey {
            case firstDayOfWeek, histories, deepseekCurrency, billingPeriod, billingDetail
            case billingTransitionAt, antigravityStatus
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            firstDayOfWeek = try? c.decodeIfPresent(String.self, forKey: .firstDayOfWeek)
            histories = try? c.decodeIfPresent([String: [String: Double]].self, forKey: .histories)
            deepseekCurrency = try? c.decodeIfPresent(String.self, forKey: .deepseekCurrency)
            billingPeriod = try? c.decodeIfPresent(String.self, forKey: .billingPeriod)
            billingDetail = try? c.decodeIfPresent(String.self, forKey: .billingDetail)
            billingTransitionAt = try? c.decodeIfPresent(Double.self, forKey: .billingTransitionAt)
            antigravityStatus = try? c.decodeIfPresent(String.self, forKey: .antigravityStatus)
        }

        struct Day: Identifiable {
            var id: String
            var label: String
            var value: Double
        }

        /// Match the popover's current calendar week and its preferred first day.
        func days(for provider: AIProvider, now: Date = Date(), calendar: Calendar = .current) -> [Day]? {
            guard let history = histories?[provider.rawValue] else { return nil }
            let weekday = calendar.component(.weekday, from: now)
            let offset = firstDayOfWeek == "monday" ? (weekday + 5) % 7 : weekday - 1
            guard let start = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
                let key = formatter.string(from: date)
                let value = history[key] ?? 0
                return Day(id: key, label: labels[calendar.component(.weekday, from: date) - 1],
                           value: value.isFinite ? max(0, value) : 0)
            }
        }
    }

    var version: Int?
    var updatedAt: Double?
    var claude: Session?
    var codex: Session?
    var antigravity: Antigravity?
    var deepseek: DeepSeek?
    var processing: Processing?
    var usage: Usage?

    private enum Keys: String, CodingKey { case version, updatedAt, claude, codex, antigravity, deepseek, processing, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        claude = try? c.decodeIfPresent(Session.self, forKey: .claude)
        codex = try? c.decodeIfPresent(Session.self, forKey: .codex)
        antigravity = try? c.decodeIfPresent(Antigravity.self, forKey: .antigravity)
        deepseek = try? c.decodeIfPresent(DeepSeek.self, forKey: .deepseek)
        processing = try? c.decodeIfPresent(Processing.self, forKey: .processing)
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
    }

    /// The thread title TokenBar last saw in flight for `provider`, if any.
    func activeTitle(_ provider: AIProvider) -> String? {
        switch provider {
        case .claude:      return claude?.activeTitle
        case .codex:       return codex?.activeTitle
        case .antigravity: return antigravity?.activeTitle
        case .deepseek:    return nil
        }
    }

    /// Preserve identity (including two chats with the same title). Older
    /// snapshots still expose every counted task, with unnamed placeholders.
    func workingSessions(_ provider: AIProvider) -> [WorkingSession] {
        guard let processing else {
            return isActive(provider) ? [.init(title: activeTitle(provider))] : []
        }
        let count = processing.count(provider)
        guard count > 0 else { return [] }
        if let sessions = processing.sessions?[provider.rawValue], !sessions.isEmpty {
            return sessions + (sessions.count..<max(count, sessions.count)).map { .init(id: "unknown-\($0 + 1)") }
        }
        let names = processing.titles(provider)
        return (0..<count).map { index in
            .init(title: index < names.count ? names[index] : (index == 0 ? activeTitle(provider) : nil),
                  since: count == 1 ? processing.since : nil)
        }
    }

    func sessionQuotaRemaining(_ provider: AIProvider) -> Double? {
        let available: Bool
        let used: Double?
        let reset: Double?
        switch provider {
        case .claude: available = claude?.available == true; used = claude?.sessionPercent; reset = claude?.sessionResetAt
        case .codex: available = codex?.available == true; used = codex?.sessionPercent; reset = codex?.sessionResetAt
        case .antigravity: available = antigravity?.available == true; used = antigravity?.geminiPercent; reset = antigravity?.geminiResetAt
        case .deepseek: return nil
        }
        guard available, isEnabled(provider), let used, used.isFinite else { return nil }
        // Past its reset the window is fresh, whatever the last poll said.
        if let reset, reset <= Date().timeIntervalSince1970 { return 100 }
        return 100 - min(100, max(0, used))
    }

    /// Whether TokenBar says the provider is being used right now, and is in use at all.
    func isActive(_ provider: AIProvider) -> Bool {
        if let processing, provider != .deepseek {
            return isEnabled(provider) && processing.count(provider) > 0
        }
        switch provider {
        case .claude:      return claude?.enabled != false && claude?.active == true
        case .codex:       return codex?.enabled != false && codex?.active == true
        case .antigravity: return antigravity?.enabled != false && antigravity?.active == true
        case .deepseek:    return false
        }
    }

    /// Off in TokenBar (a missing entry counts as on: only an explicit false turns it off).
    func isEnabled(_ provider: AIProvider) -> Bool {
        switch provider {
        case .claude:      return claude?.enabled != false
        case .codex:       return codex?.enabled != false
        case .antigravity: return antigravity?.enabled != false
        case .deepseek:    return deepseek?.enabled != false
        }
    }

    /// The first limit shown in each provider's bars. A countdown is meaningful
    /// only when the provider reports 0% left and a reset still lies ahead.
    func exhaustedPrimaryLimits(now: Date = Date()) -> [ExhaustedPrimaryLimit] {
        let deadline = now.timeIntervalSince1970
        var limits: [ExhaustedPrimaryLimit] = []
        if claude?.enabled != false, claude?.available == true,
           let used = claude?.sessionPercent, used >= 100,
           let reset = claude?.sessionResetAt, reset > deadline {
            limits.append(.init(provider: .claude, resetAt: reset))
        }
        if codex?.enabled != false, codex?.available == true,
           let used = codex?.sessionPercent, used >= 100,
           let reset = codex?.sessionResetAt, reset > deadline {
            limits.append(.init(provider: .codex, resetAt: reset))
        }
        if antigravity?.enabled != false, antigravity?.available == true,
           let used = antigravity?.geminiPercent, used >= 100,
           let reset = antigravity?.geminiResetAt, reset > deadline {
            limits.append(.init(provider: .antigravity, resetAt: reset))
        }
        return limits
    }

    /// The numbers whose rise means the provider just did work (used percents, in a fixed order).
    fileprivate func usedPercents(_ provider: AIProvider) -> [Double?] {
        switch provider {
        case .claude:      return [claude?.sessionPercent, claude?.weekPercent]
        case .codex:       return [codex?.sessionPercent, codex?.weekPercent]
        case .antigravity: return [antigravity?.geminiPercent, antigravity?.claudeGptPercent]
        case .deepseek:    return []
        }
    }
}

// MARK: - Feed

/// Reads TokenBar's snapshot file and tells the esc-spot widget when it changes, and which AI was
/// used last. TokenBar posts a distributed notification after each write; while the strip shows, a
/// slow timer also checks the file's modification time in case a notification was missed.
final class AIUsageFeed {
    static let shared = AIUsageFeed()

    /// A snapshot older than this is shown dimmed: TokenBar has stopped updating it.
    static let staleAfter: TimeInterval = 15 * 60
    /// Used only by old TokenBar snapshots and DeepSeek, which have no task counts.
    static let activeWindow: TimeInterval = 3 * 60
    private static let completionGrace: TimeInterval = 8
    private static let processingStaleAfter: TimeInterval = 2 * 60 + 30
    private static let checkInterval: TimeInterval = 15

    private static let snapshotChanged = Notification.Name("com.h1d3s1gn.TokenBar.snapshotUpdated")
    private static let showPopoverName = Notification.Name("com.h1d3s1gn.TokenBar.showPopover")
    private static let claudeSignInName = Notification.Name("com.h1d3s1gn.TokenBar.claudeSignIn")

    private(set) var snapshot: TokenBarSnapshot?
    /// False while TokenBar isn't running. The snapshot on disk is then a leftover
    /// whose numbers only look current, so every reader treats it as stale.
    private(set) var isTokenBarRunning = true
    static let tokenBarBundleID = "com.tokenbar.app"

    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenBar/widget-snapshot.json")
    private var observers: [(TokenBarSnapshot?) -> Void] = []
    private var started = false
    private var watching = false
    private var timer: Timer?
    private var loadedModified: Date?
    /// When each provider's numbers last moved, for "recently active".
    private var lastMoved: [AIProvider: Date] = [:]
    private var lastStarted: [AIProvider: Date] = [:]
    private var lastStopped: [AIProvider: Date] = [:]
    private let queue = DispatchQueue(label: "AIUsageFeed.read", qos: .utility)
    private var readToken = 0

    private init() {}

    /// Called on the main thread with each new snapshot, nil when the file is gone.
    func addObserver(_ cb: @escaping (TokenBarSnapshot?) -> Void) { observers.append(cb) }

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: Self.snapshotChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.load() }
        PresentationState.shared.addObserver { [weak self] in self?.updateTimer() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.tokenBarBundleID else { return }
                self?.updateTokenBarRunning()
            }
        }
        isTokenBarRunning = Self.tokenBarIsRunning()
        load()
    }

    private static func tokenBarIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: tokenBarBundleID)
            .contains { !$0.isTerminated }
    }

    private func updateTokenBarRunning() {
        let running = Self.tokenBarIsRunning()
        guard running != isTokenBarRunning else { return }
        isTokenBarRunning = running
        observers.forEach { $0(snapshot) }
        // A relaunched TokenBar rewrites the snapshot within seconds; pick it up.
        if running { load() }
    }

    /// Opens TokenBar (from the notch's "TokenBar isn't running" card).
    static func openTokenBar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tokenBarBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// While the strip shows the widget, the file is also polled for changes (gated like the
    /// other pollers: not while the screen is locked or the displays sleep).
    func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        updateTimer()
    }

    private func updateTimer() {
        guard watching, PresentationState.shared.canPresent else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        // Missed while it wasn't watching: catch up at once.
        checkModified()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.checkModified()
        }
        timer.tolerance = 3
        self.timer = timer
    }

    private func checkModified() {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != loadedModified else { return }
        load()
    }

    private func load() {
        readToken += 1
        let token = readToken
        let url = url
        queue.async { [weak self] in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let next = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TokenBarSnapshot.self, from: $0) }
            DispatchQueue.main.async {
                // A newer read is on its way: this one is already out of date.
                guard let self, token == self.readToken else { return }
                self.loadedModified = modified
                self.apply(next)
            }
        }
    }

    func apply(_ next: TokenBarSnapshot?) {
        if let processing = next?.processing {
            let now = Date()
            for provider in [AIProvider.claude, .codex, .antigravity] {
                let before = snapshot?.processing?.count(provider) ?? 0
                let after = processing.count(provider)
                if after > 0, before == 0 {
                    lastStarted[provider] = now
                    lastStopped.removeValue(forKey: provider)
                } else if after == 0, before > 0 {
                    lastStopped[provider] = now
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionGrace) { [weak self] in
                        guard let self else { return }
                        self.observers.forEach { $0(self.snapshot) }
                    }
                }
            }
        }
        if let previous = snapshot, let next {
            let now = Date()
            for provider in AIProvider.allCases where Self.moved(provider, from: previous, to: next) {
                lastMoved[provider] = now
            }
        }
        snapshot = next
        observers.forEach { $0(next) }
    }

    /// Used percent up (a reset to zero is not work), or DeepSeek's balance down.
    private static func moved(_ provider: AIProvider, from old: TokenBarSnapshot, to new: TokenBarSnapshot) -> Bool {
        if provider == .deepseek {
            guard let before = old.deepseek?.balance, let after = new.deepseek?.balance else { return false }
            return after < before - 1e-9
        }
        for (before, after) in zip(old.usedPercents(provider), new.usedPercents(provider)) {
            if let before, let after, after > before + 1e-9 { return true }
        }
        return false
    }

    // MARK: Freshness and activity

    var isStale: Bool {
        guard isTokenBarRunning else { return snapshot != nil }
        guard let updated = snapshot?.updatedAt else { return snapshot != nil }
        return Date().timeIntervalSince1970 - updated > Self.staleAfter
    }

    /// Task counts have their own heartbeat because provider polling can be much slower.
    var isProcessingFresh: Bool {
        guard isTokenBarRunning else { return false }
        guard let snapshot, let processing = snapshot.processing,
              let updated = processing.updatedAt ?? snapshot.updatedAt else { return false }
        let age = Date().timeIntervalSince1970 - updated
        return age >= -30 && age < Self.processingStaleAfter
    }

    /// When the provider was last known to be working: now while TokenBar flags it active,
    /// else when its numbers last moved. Nil when neither is recent enough to matter.
    private func activity(_ provider: AIProvider) -> Date? {
        guard let snapshot, snapshot.isEnabled(provider) else { return nil }
        if snapshot.processing != nil, provider != .deepseek {
            guard isProcessingFresh else { return nil }
            if snapshot.isActive(provider) { return lastStarted[provider] ?? Date() }
            guard let stopped = lastStopped[provider], Date().timeIntervalSince(stopped) < Self.completionGrace else { return nil }
            return stopped
        }
        guard !isStale else { return nil }
        if snapshot.isActive(provider) { return Date() }
        guard let moved = lastMoved[provider], Date().timeIntervalSince(moved) < Self.activeWindow else { return nil }
        return moved
    }

    /// Active tasks, a brief completion grace, or legacy usage movement.
    func isRecentlyActive(_ provider: AIProvider) -> Bool { activity(provider) != nil }

    var anyRecentlyActive: Bool { AIProvider.allCases.contains { isRecentlyActive($0) } }

    /// The provider that worked last; one actively processing wins over recent completion.
    var mostRecentlyActiveProvider: AIProvider? {
        let recent = AIProvider.allCases.filter { isRecentlyActive($0) }
        let flagged = recent.filter { snapshot?.isActive($0) == true }
        func lastActivity(_ provider: AIProvider) -> Date {
            if snapshot?.isActive(provider) == true { return lastStarted[provider] ?? lastMoved[provider] ?? .distantPast }
            return lastStopped[provider] ?? lastMoved[provider] ?? .distantPast
        }
        return (flagged.isEmpty ? recent : flagged).max {
            lastActivity($0) < lastActivity($1)
        }
    }

    /// Asks TokenBar to open its popover.
    /// `anchor`: the widget's rect in screen coordinates, for TokenBar to open above.
    static func showPopover(anchor: CGRect? = nil) {
        let info: [String: Double]? = anchor.map {
            ["x": Double($0.minX), "y": Double($0.minY), "width": Double($0.width), "height": Double($0.height)]
        }
        DistributedNotificationCenter.default().postNotificationName(
            showPopoverName, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// Asks TokenBar to open its Claude sign-in window (it ignores this unless
    /// the login really needs the user).
    static func requestClaudeSignIn() {
        DistributedNotificationCenter.default().postNotificationName(
            claudeSignInName, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
