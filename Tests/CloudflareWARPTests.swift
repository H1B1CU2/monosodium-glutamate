import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    expect(condition(), "Timed out waiting for WARP callback")
}

private final class FakeClient {
    private let lock = NSLock()
    private var payload = Data(#"{"status":"Disconnected"}"#.utf8)
    private var mutations: [String] = []
    var rejectMutation = false

    func status(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        payload = Data(json.utf8)
    }

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return mutations
    }

    func run(_ arguments: [String]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if arguments == ["--json", "status"] { return payload }
        expect(arguments.count == 1, "Must not accept terms, register, or change client mode")
        mutations.append(arguments[0])
        if rejectMutation { throw CloudflareWARP.CommandError.failed("Connection blocked") }
        return Data("Success".utf8)
    }
}

@main
struct CloudflareWARPTests {
    static func main() throws {
        let fake = FakeClient()
        let client = CloudflareWARP(command: fake.run)
        var originalCallbackCount = 0
        var observerCount = 0
        client.onChange = { originalCallbackCount += 1 }
        client.addObserver { observerCount += 1 }
        client.refresh()
        wait { client.state == .disconnected }
        expect(fake.commands.isEmpty, "Reading state must never toggle the VPN")
        expect(originalCallbackCount == 1 && observerCount == 1,
               "Status changes reach the strip and notch without replacing either callback")

        // The menu changed the real state since the last poll. The next key
        // press must disconnect, rather than using the cached off state.
        fake.status(#"{"status":"Connected"}"#)
        client.toggle()
        client.toggle()
        wait { !client.commandInFlight }
        expect(fake.commands == ["disconnect"], "Fresh state wins; overlapping presses run once")

        let connecting = FakeClient()
        connecting.status(#"{"status":{"Connecting":{"stage":"Resolving"}}}"#)
        let pending = CloudflareWARP(command: connecting.run)
        pending.toggle()
        wait { !pending.commandInFlight }
        expect(connecting.commands == ["disconnect"], "A second press can cancel a pending connection")

        let failed = FakeClient()
        failed.rejectMutation = true
        let denied = CloudflareWARP(command: failed.run)
        var failure: String?
        denied.onToggleFailure = { failure = $0 }
        denied.toggle()
        wait { !denied.commandInFlight }
        expect(denied.state == .failed && failure == "Connection blocked", "Command errors reach the caller")

        let malformed = FakeClient()
        malformed.status(#"{"status":"NewUnknownState"}"#)
        let unknown = CloudflareWARP(command: malformed.run)
        unknown.toggle()
        wait { !unknown.commandInFlight }
        expect(malformed.commands.isEmpty, "An unreadable state must not guess a VPN command")

        // A large stderr response must be drained and returned as a failure,
        // rather than hanging on a full pipe.
        do {
            _ = try CloudflareWARP.runCommand(["-c", "import sys; sys.stderr.write('x' * 200000); sys.exit(7)"],
                                             executable: URL(fileURLWithPath: "/usr/bin/python3"))
            fatalError("Nonzero exit must fail")
        } catch CloudflareWARP.CommandError.failed(let message) {
            expect(message.count == 200000, "Preserve daemon diagnostics")
        }
        let started = Date()
        do {
            _ = try CloudflareWARP.runCommand(["-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(5)"],
                                             executable: URL(fileURLWithPath: "/usr/bin/python3"), timeout: 0.2)
            fatalError("A hung client must time out")
        } catch {}
        expect(Date().timeIntervalSince(started) < 2, "Even a client ignoring SIGTERM cannot leave the key blocked")

        // Installed-client integration is read-only; it never changes routing.
        let live = try CloudflareWARP.runCommand(["--json", "status"])
        expect(CloudflareWARP.State.parse(live) != nil, "Parse the installed WARP version's status")
        print("Cloudflare WARP checks passed (live status read only)")
    }
}
