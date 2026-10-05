import AppKit

// Run: swiftc MSG/AIUsageFeed.swift Tests/AIUsageFeedTests.swift -o /tmp/ai-usage-feed && /tmp/ai-usage-feed
// The feed only needs this presentation hook when its file watcher is started.
final class PresentationState {
    static let shared = PresentationState()
    let canPresent = true
    func addObserver(_ callback: @escaping () -> Void) {}
}

@main
struct AIUsageFeedTests {
    static func main() throws {
        let now = Date().timeIntervalSince1970
        func snapshot(count: Int?, active: Bool, updatedAt: Double) throws -> TokenBarSnapshot {
            let processing = count.map {
                "\"processing\":{\"claude\":0,\"codex\":\($0),\"antigravity\":0,\"updatedAt\":\(updatedAt)},"
            } ?? ""
            let json = "{\"updatedAt\":\(now),\(processing)\"codex\":{\"enabled\":true,\"available\":true,\"active\":\(active)}}"
            return try JSONDecoder().decode(TokenBarSnapshot.self, from: Data(json.utf8))
        }

        let feed = AIUsageFeed.shared
        let legacy = try snapshot(count: nil, active: true, updatedAt: now)
        precondition(legacy.isActive(.codex), "Older TokenBar snapshots keep their active-flag fallback")

        let idle = try snapshot(count: 0, active: true, updatedAt: now)
        feed.apply(idle)
        precondition(!idle.isActive(.codex) && !feed.anyRecentlyActive,
                     "Fresh task counts override a stale usage-poll active flag")

        let working = try snapshot(count: 1, active: false, updatedAt: now)
        feed.apply(working)
        precondition(working.isActive(.codex) && feed.isRecentlyActive(.codex)
                     && feed.mostRecentlyActiveProvider == .codex,
                     "A task appears without waiting for usage polling")

        let finished = try snapshot(count: 0, active: false, updatedAt: now)
        feed.apply(finished)
        precondition(feed.isRecentlyActive(.codex), "Completion gets a short visual grace")

        let stale = try snapshot(count: 1, active: false, updatedAt: now - 600)
        feed.apply(stale)
        precondition(!feed.isProcessingFresh && !feed.isRecentlyActive(.codex),
                     "An abandoned processing snapshot cannot keep a task visible")

        let limitsJSON = """
        {"updatedAt":\(now),
         "claude":{"enabled":true,"available":true,"sessionPercent":100,"sessionResetAt":\(now + 600)},
         "codex":{"enabled":true,"available":true,"sessionPercent":50,"weekPercent":100,"sessionResetAt":\(now + 600)},
         "antigravity":{"enabled":true,"available":true,"geminiPercent":100,"geminiResetAt":\(now + 600)}}
        """
        let limits = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data(limitsJSON.utf8))
        precondition(limits.exhaustedPrimaryLimits(now: Date(timeIntervalSince1970: now)).map(\.provider)
                     == [.claude, .antigravity],
                     "Only exhausted primary limits with future resets get the quota card")
        precondition(limits.exhaustedPrimaryLimits(now: Date(timeIntervalSince1970: now + 601)).isEmpty,
                     "The quota card disappears after its reset time")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        precondition(UsageResetCountdown.text(until: fixed.timeIntervalSince1970 + 8_340, now: fixed)
                     == "2 hr 19 min left", "The lock-screen card uses the Esc countdown wording")
        precondition(UsageResetCountdown.text(until: fixed.timeIntervalSince1970 + 234, now: fixed)
                     == "3 min 54 sec", "Short countdowns show seconds")
        precondition(UsageResetCountdown.text(until: fixed.timeIntervalSince1970, now: fixed)
                     == "ready", "Elapsed countdowns do not show negative time")

        let sessionJSON = """
        {"updatedAt":\(now),"codex":{"enabled":true,"available":true,"sessionPercent":19},
         "processing":{"codex":2,"updatedAt":\(now),"sessions":{"codex":[
           {"id":"a","title":"Same title","since":\(now - 480),"activity":"Building project","completedSteps":3,"totalSteps":5},
           {"id":"b","title":"Same title","since":\(now - 120),"activity":"Reading files","totalSteps":"invalid"}]}}}
        """
        let detailed = try JSONDecoder().decode(TokenBarSnapshot.self, from: Data(sessionJSON.utf8))
        let sessions = detailed.workingSessions(.codex)
        precondition(sessions.count == 2 && sessions.map(\.id) == ["a", "b"],
                     "Duplicate titles do not collapse distinct sessions")
        precondition(sessions[0].since != sessions[1].since && sessions[0].completedSteps == 3 && sessions[1].totalSteps == nil,
                     "Per-session clocks and tolerant optional progress survive decoding")
        precondition(detailed.sessionQuotaRemaining(.codex) == 81)
        precondition(limits.sessionQuotaRemaining(.claude) == 0)
        precondition(working.sessionQuotaRemaining(.codex) == nil, "A missing quota does not become 100% left")
        let unnamed = try snapshot(count: 3, active: false, updatedAt: now)
        precondition(unnamed.workingSessions(.codex).count == 3,
                     "Older snapshots still show every counted session, including unnamed ones")
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let exported = try JSONDecoder().decode(TokenBarSnapshot.self, from: data)
            let incoming = exported.workingSessions(.codex)
            precondition(incoming.count == 2 && incoming[0].title == "Contract title" && incoming[0].since == 1000,
                         "MSG decodes TokenBar's actual session encoding with Unix dates")
            precondition(incoming[0].activity == "Building project" && incoming[0].completedSteps == 3 && incoming[0].totalSteps == 5)
        }
        print("AI usage feed activity checks passed")
    }
}
