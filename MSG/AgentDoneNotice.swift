import AppKit

// MARK: - AI tasks finishing, in the notch
//
// When a Claude, Codex or Antigravity session TokenBar sees working stops, the
// notch says so: "Claude finished", the thread's name, what you asked for in
// that turn (TokenBar reads it from the log), and how long it ran. A
// session counts as finished once it has stayed gone for a few seconds (the
// scan can drop one for a moment), and only after a run long enough that you
// may have looked away. Claude's sub-agents finish inside their main session's
// turn and aren't announced. Nothing is said while TokenBar's report is stale: a
// session missing from an old report hasn't necessarily finished. A click on the
// notice opens the app the task ran in, on its session (AgentSessionLink).

final class AgentDoneNotice {
    static let shared = AgentDoneNotice()

    private struct Run {
        let provider: AIProvider
        /// TokenBar's id for it: Claude's session, Codex's thread, Antigravity's
        /// conversation. Nil for its placeholders.
        var session: String?
        var title: String?
        var prompt: String?
        var destination: TokenBarSnapshot.WorkingSession.Destination? = nil
        /// When it began: TokenBar's own time when it has one, else first seen.
        var since: Date
    }

    /// Sessions working in the last report, keyed "provider:session id".
    private var running: [String: Run] = [:]
    /// Sessions gone from the report, waiting out the grace before they count.
    private var leaving: [String: DispatchWorkItem] = [:]
    /// Finished but not shown yet (no notch on screen), with when they finished.
    private var pending: [(notice: NotchHUDView.Notice, at: Date)] = []
    private var started = false

    /// Gone this long before it counts as finished.
    private static let grace: TimeInterval = 8
    /// Shorter runs finish while you're still watching them.
    private static let minimumRun: TimeInterval = 15
    /// Not shown by then (screen locked): the lock screen card said it already.
    private static let keepFor: TimeInterval = 5 * 60
    /// TokenBar's processing heartbeat comes every 60 s; older than this is stale.
    private static let staleAfter: TimeInterval = 150

    private init() {}

    private var enabled: Bool { AppSettings.shared.notchAgentDoneNotice }

    func start() {
        guard !started else { return }
        started = true
        AIUsageFeed.shared.addObserver { [weak self] snapshot in self?.update(snapshot) }
        AIUsageFeed.shared.start()
        PresentationState.shared.addObserver { [weak self] in self?.flush() }
        // For trying the card: post `H1D3S1GN.MSG.debug.agentDone` with a provider
        // ("claude", "codex", "antigravity") as its object.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("H1D3S1GN.MSG.debug.agentDone"),
                                                            object: nil, queue: .main) { [weak self] note in
            let provider = (note.object as? String).flatMap(AIProvider.init(rawValue:)) ?? .claude
            let run = Run(provider: provider, session: nil, title: "Sample thread", prompt: "Sample request",
                          since: Date(timeIntervalSinceNow: -185))
            self?.pending.append((Self.notice(for: run, endedAt: Date()), Date()))
            self?.flush()
        }
        update(AIUsageFeed.shared.snapshot)
    }

    /// The setting flipped. Main thread.
    func settingChanged() {
        if !enabled { pending.removeAll() }
    }

    private func update(_ snapshot: TokenBarSnapshot?) {
        guard let snapshot, let processing = snapshot.processing, let updatedAt = processing.updatedAt,
              Date().timeIntervalSince1970 - updatedAt < Self.staleAfter else {
            // TokenBar has gone quiet: start over from its next report.
            running.removeAll()
            leaving.values.forEach { $0.cancel() }
            leaving.removeAll()
            return
        }
        var current: [String: Run] = [:]
        for provider in [AIProvider.claude, .codex, .antigravity] {
            for (index, session) in snapshot.workingSessions(provider).enumerated()
            where !(session.id ?? "").hasPrefix("agent-") {
                let key = "\(provider.rawValue):\(session.id ?? "#\(index)")"
                let since = session.since.map { Date(timeIntervalSince1970: $0) } ?? running[key]?.since ?? Date()
                let id = session.id.flatMap { $0.hasPrefix("unknown-") ? nil : $0 }
                current[key] = Run(provider: provider, session: id, title: session.title,
                                   prompt: session.prompt ?? running[key]?.prompt,
                                   destination: session.destination ?? running[key]?.destination, since: since)
            }
        }
        // Back within its grace: it never stopped.
        for key in current.keys { leaving.removeValue(forKey: key)?.cancel() }
        let endedAt = Date()
        for (key, run) in running where current[key] == nil && leaving[key] == nil {
            let work = DispatchWorkItem { [weak self] in self?.finished(key, run, endedAt: endedAt) }
            leaving[key] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
        }
        // Those waiting out their grace stay listed until it's over.
        running = running.filter { leaving[$0.key] != nil }.merging(current) { _, new in new }
    }

    private func finished(_ key: String, _ run: Run, endedAt: Date) {
        leaving[key] = nil
        running[key] = nil
        guard enabled, endedAt.timeIntervalSince(run.since) >= Self.minimumRun else { return }
        pending.append((Self.notice(for: run, endedAt: endedAt), endedAt))
        flush()
    }

    /// Shows what's waiting, oldest first, while the notch takes them.
    private func flush() {
        pending.removeAll { Date().timeIntervalSince($0.at) >= Self.keepFor }
        while let first = pending.first, NotchHUD.shared.showNotice(first.notice) {
            pending.removeFirst()
        }
    }

    /// "Codex finished · Review YouTube video" over the request itself; without
    /// one, the thread's name goes underneath instead.
    private static func notice(for run: Run, endedAt: Date) -> NotchHUDView.Notice {
        func clean(_ text: String?) -> String? {
            let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        let finished = "\(AgentActivityCardView.name(for: run.provider)) finished"
        let title = clean(run.title), prompt = clean(run.prompt)
        return .init(provider: run.provider,
                     title: prompt != nil && title != nil ? "\(finished) · \(title!)" : finished,
                     detail: prompt ?? title ?? "Task finished",
                     value: duration(endedAt.timeIntervalSince(run.since)),
                     link: AgentSessionLink(provider: run.provider, session: run.session, destination: run.destination))
    }

    /// Short enough for the notch's wing: "45s", "12m", "1h 5m".
    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

// MARK: - Opening a finished task

/// A finished task's session, opened from its notice: Claude's desktop app on
/// that Claude Code session, the Codex app on that thread, or, for a task run
/// in a terminal or an editor, that app brought forward (the session is
/// wherever it was left). Antigravity just comes forward.
struct AgentSessionLink: Equatable {
    let provider: AIProvider
    let session: String?
    var destination: TokenBarSnapshot.WorkingSession.Destination? = nil

    var helpText: String {
        if destination?.url != nil || (destination == nil && session != nil && provider != .antigravity) {
            return "Open this session"
        }
        return "Open the app for this task"
    }

    private enum Target {
        case url(URL)
        case app(URL)
    }

    private static let claudeApp = "com.anthropic.claudefordesktop"
    private static let codexApp = "com.openai.codex"

    func open() {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = self.target()
            DispatchQueue.main.async {
                switch target {
                case .url(let url)?:
                    if !NSWorkspace.shared.open(url), let fallback = Self.app(self.providerBundleID),
                       case .app(let appURL) = fallback {
                        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                case .app(let url)?:
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                case nil: NSSound.beep()
                }
            }
        }
    }

    /// Off the main thread: it reads files and walks processes.
    private func target() -> Target? {
        if let destination {
            if let url = Self.sessionURL(provider: provider, session: session, destination: destination),
               destination.bundleID == providerBundleID { return .url(url) }
            if let bundle = destination.bundleID,
               bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil,
               let app = Self.app(bundle) { return app }
        }
        guard let session, session.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
        else { return Self.app(providerBundleID) }
        // The app the agent's process runs under, from the pid its hooks last wrote.
        let owner = Self.owner(of: Self.hookPID(provider, session))
        switch provider {
        case .claude:
            if owner == nil || owner?.bundleIdentifier == Self.claudeApp,
               let id = Self.claudeDesktopSession(cli: session),
               let url = URL(string: "claude://code/continue?session=\(id)") { return .url(url) }
            if owner == nil || owner?.bundleIdentifier == Self.claudeApp,
               let url = Self.sessionURL(provider: provider, session: session, destination: nil) { return .url(url) }
            return (owner?.bundleURL).map(Target.app) ?? Self.app(Self.claudeApp)
        case .codex:
            if let owner, owner.bundleIdentifier != Self.codexApp, let url = owner.bundleURL { return .app(url) }
            return URL(string: "codex://threads/\(session)").map(Target.url)
        case .antigravity:
            return Self.app("com.google.antigravity")
        case .deepseek:
            return nil
        }
    }

    private var providerBundleID: String {
        switch provider {
        case .claude: return Self.claudeApp
        case .codex: return Self.codexApp
        case .antigravity: return "com.google.antigravity"
        case .deepseek: return ""
        }
    }

    /// Only the provider's known session routes are accepted from the snapshot.
    static func sessionURL(provider: AIProvider, session: String?,
                           destination: TokenBarSnapshot.WorkingSession.Destination?) -> URL? {
        if let raw = destination?.url, let parts = URLComponents(string: raw),
           parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil {
            switch provider {
            case .codex:
                if parts.scheme == "codex", parts.host == "threads", let session,
                   session.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
                   parts.path == "/\(session)", parts.query == nil { return parts.url }
            case .claude:
                let items = parts.queryItems ?? []
                if parts.scheme == "claude", items.count == 1, items.first?.name == "session",
                   let id = items.first?.value {
                    if parts.host == "resume", parts.path.isEmpty, id == session, UUID(uuidString: id) != nil { return parts.url }
                    if parts.host == "code", parts.path == "/continue",
                       id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil { return parts.url }
                }
            case .antigravity, .deepseek: break
            }
            return nil
        }
        guard let session else { return nil }
        switch provider {
        case .claude:
            if UUID(uuidString: session) != nil { return URL(string: "claude://resume?session=\(session)") }
            if session.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil {
                return URL(string: "claude://code/continue?session=\(session)")
            }
        case .codex:
            if session.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil {
                return URL(string: "codex://threads/\(session)")
            }
        case .antigravity, .deepseek: break
        }
        return nil
    }

    private static func app(_ bundleID: String) -> Target? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(Target.app)
    }

    /// TokenBar's hook record for the session: `agent-hooks/<claude|codex>/<id>.json`.
    private static func hookPID(_ provider: AIProvider, _ session: String) -> pid_t? {
        guard provider == .claude || provider == .codex else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBar/agent-hooks/\(provider.rawValue)/\(session).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 1 else { return nil }
        return pid
    }

    /// The first ordinary app up the process's parents: Claude, Codex, Terminal,
    /// an editor. Nil when the process has gone.
    private static func owner(of pid: pid_t?) -> NSRunningApplication? {
        var pid = pid
        for _ in 0..<16 {
            guard let current = pid, current > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            pid = parent(of: current)
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Claude's desktop app keeps each Code session it runs as
    /// `claude-code-sessions/<account>/<org>/local_<id>.json`, with the CLI's
    /// session id inside; its `claude://code/continue` link takes the `local_` one.
    private static func claudeDesktopSession(cli id: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let needle = Data(id.utf8)
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["cliSessionId"] as? String == id, let local = object["sessionId"] as? String,
                  local.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { continue }
            return local
        }
        return nil
    }
}
