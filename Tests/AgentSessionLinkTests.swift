// Concatenated with the production notice controller by run_agent_session_tests.sh.
final class PresentationState {
    static let shared = PresentationState()
    let canPresent = true
    func addObserver(_ callback: @escaping () -> Void) {}
}
final class AppSettings { static let shared = AppSettings(); var notchAgentDoneNotice = true }
enum AgentActivityCardView {
    static func name(for provider: AIProvider) -> String { provider.rawValue.capitalized }
}
enum NotchHUDView {
    struct Notice {
        let provider: AIProvider
        let title: String
        let detail: String
        let value: String
        var link: AgentSessionLink?
    }
}
final class NotchHUD {
    static let shared = NotchHUD()
    var notices: [NotchHUDView.Notice] = []
    func showNotice(_ notice: NotchHUDView.Notice) -> Bool { notices.append(notice); return true }
}

extension AgentDoneNotice {
    static func runChecks() throws {
        let snapshot = try JSONDecoder().decode(TokenBarSnapshot.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let codex = snapshot.workingSessions(.codex)
        precondition(codex.count == 2)
        for session in codex {
            precondition(AgentSessionLink.sessionURL(provider: .codex, session: session.id, destination: session.destination)?.absoluteString
                         == "codex://threads/\(session.id!)", "TokenBar and MSG share the exact destination")
        }
        let claude = snapshot.workingSessions(.claude)[0]
        precondition(AgentSessionLink.sessionURL(provider: .claude, session: claude.id, destination: claude.destination)?.host == "code")
        let tracker = AgentDoneNotice()
        tracker.update(snapshot)
        let key = "codex:\(codex[0].id!)"
        var run = tracker.running[key]!
        run.since = Date(timeIntervalSinceNow: -30)
        tracker.running[key] = run
        var idle = snapshot
        idle.processing?.codex = 1
        idle.processing?.sessions?["codex"] = [codex[1]]
        tracker.update(idle)
        precondition(tracker.leaving[key] != nil && tracker.leaving.count == 1)
        tracker.leaving[key]?.cancel()
        tracker.finished(key, run, endedAt: Date())
        let link = NotchHUD.shared.notices.last!.link!
        precondition(link.session == codex[0].id && link.destination == codex[0].destination,
                     "Finished notices retain the departed session's destination")
        precondition(tracker.running["codex:\(codex[1].id!)"] != nil, "Another session stays running")
        tracker.update(nil)
        precondition(tracker.running.isEmpty && tracker.leaving.isEmpty, "A stale feed never invents completions")
        let placeholder = Self.notice(for: Run(provider: .codex, session: nil, title: nil, prompt: nil,
                                                since: Date(timeIntervalSinceNow: -30)), endedAt: Date())
        precondition(placeholder.link != nil && placeholder.link?.helpText == "Open the app for this task")

        let id = codex[0].id!
        for raw in ["https://example.com", "file:///tmp/foo", "codex://threads/other", "codex://threads/\(id)?prompt=bad"] {
            precondition(AgentSessionLink.sessionURL(provider: .codex, session: id,
                destination: .init(url: raw, bundleID: "com.openai.codex")) == nil)
        }
        let old = try JSONDecoder().decode(TokenBarSnapshot.WorkingSession.self, from: Data("{\"id\":\"\(id)\"}".utf8))
        precondition(old.destination == nil && AgentSessionLink.sessionURL(provider: .codex, session: id, destination: nil) != nil)
        let malformed = try JSONDecoder().decode(TokenBarSnapshot.WorkingSession.self,
            from: Data("{\"id\":\"\(id)\",\"destination\":{\"url\":42}}".utf8))
        precondition(malformed.id == id && malformed.destination == nil, "Bad optional metadata doesn't lose the session")
        print("PASS: TokenBar to MSG destinations, completion retention, app fallback, legacy and invalid links")
    }
}

@main
struct AgentSessionLinkTests {
    static func main() throws { try AgentDoneNotice.runChecks() }
}
