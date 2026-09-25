import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@main
struct TilingFramePipelineTests {
    static func main() {
        skipsUnchangedAttributes()
        coalescesBacklogAndCommitsLastTarget()
        cancellationRestoresBeforeNextGesture()
        slowAppDoesNotBlockAnotherApp()
        print("PASS: latest-only frame backlog, final target, lifecycle, cancellation and per-app isolation")
    }

    static func skipsUnchangedAttributes() {
        let frame = CGRect(x: 750, y: 38, width: 757, height: 939)
        expect(TilingFrameWritePlan(previous: frame, target: frame).isEmpty, "idle targets must produce no AX writes")
        let resize = TilingFrameWritePlan(previous: frame, target: CGRect(x: 750, y: 38, width: 800, height: 939))
        expect(resize.size && !resize.position, "left tile resize must not redundantly move its origin")
        let move = TilingFrameWritePlan(previous: frame, target: frame.offsetBy(dx: 10, dy: 0))
        expect(move.position && !move.size, "a move must not force a window-content relayout")
        let coupled = TilingFrameWritePlan(previous: frame, target: CGRect(x: 700, y: 38, width: 807, height: 939))
        expect(coupled.position && coupled.size, "anchored right tile must update both attributes")
        let retry = TilingFrameWritePlan(previous: nil, target: frame)
        expect(retry.position && retry.size, "closing retry must bypass the accepted-frame cache")
    }

    static func coalescesBacklogAndCommitsLastTarget() {
        let events = Events()
        let queue = DispatchQueue(label: "test.frames")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lane = TilingLatestFrameLane<Int, String>(queue: queue,
            begin: { events.add("begin") }, write: { value in
                events.add(value)
                if value == "first" { entered.signal(); release.wait() }
            }, settle: { events.add("settle:" + $0) }, end: { events.add("end") })
        lane.submit("first", for: 1)
        expect(entered.wait(timeout: .now() + 2) == .success, "first write did not start")
        for index in 0..<1000 { lane.submit("right-\(index)", for: 1) }
        lane.submit("left-final", for: 2)
        lane.finish { done.signal() }
        lane.submit("invalid-after-end", for: 1)
        release.signal()
        expect(done.wait(timeout: .now() + 2) == .success, "finish timed out")
        let output = events.snapshot
        expect(output.filter { $0 == "begin" }.count == 1, "enhanced UI must be disabled once per gesture")
        expect(output.filter { $0.hasPrefix("right-") } == ["right-999"], "stale frames must collapse")
        expect(output.contains("left-final"), "second window must not be starved")
        expect(output.contains("settle:right-999") && output.contains("settle:left-final"), "final targets must settle")
        expect(!output.contains("settle:first") && !output.contains("invalid-after-end"), "stale target escaped")
        expect(output.last == "end", "preference restoration must follow the final target")
    }

    static func cancellationRestoresBeforeNextGesture() {
        let events = Events()
        let queue = DispatchQueue(label: "test.same-app")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let oldDone = DispatchSemaphore(value: 0)
        let newDone = DispatchSemaphore(value: 0)
        let old = TilingLatestFrameLane<Int, Int>(queue: queue,
            begin: { events.add("old-begin") }, write: { _ in
                events.add("old-pair"); entered.signal(); release.wait()
            }, settle: { _ in events.add("bad-old-settle") }, end: { events.add("old-end") })
        old.submit(1, for: 1)
        expect(entered.wait(timeout: .now() + 2) == .success, "old write did not start")
        old.submit(2, for: 1)
        old.finish(cancel: true) { oldDone.signal() }
        let new = TilingLatestFrameLane<Int, Int>(queue: queue,
            begin: { events.add("new-begin") }, write: { _ in events.add("new-pair") },
            settle: { _ in events.add("new-settle") }, end: { events.add("new-end") })
        new.submit(3, for: 1)
        new.finish { newDone.signal() }
        release.signal()
        expect(oldDone.wait(timeout: .now() + 2) == .success, "cancel cleanup timed out")
        expect(newDone.wait(timeout: .now() + 2) == .success, "next gesture timed out")
        expect(events.snapshot == ["old-begin", "old-pair", "old-end", "new-begin", "new-pair", "new-settle", "new-end"],
               "cancelled work must restore before the next gesture, without writing stale targets")
    }

    static func slowAppDoesNotBlockAnotherApp() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let slowDone = DispatchSemaphore(value: 0)
        let fastDone = DispatchSemaphore(value: 0)
        let slow = TilingLatestFrameLane<Int, Int>(queue: DispatchQueue(label: "test.slow"),
            begin: {}, write: { _ in entered.signal(); release.wait() }, settle: { _ in }, end: {})
        let fast = TilingLatestFrameLane<Int, Int>(queue: DispatchQueue(label: "test.fast"),
            begin: {}, write: { _ in }, settle: { _ in }, end: {})
        slow.submit(1, for: 1)
        expect(entered.wait(timeout: .now() + 2) == .success, "slow app did not start")
        fast.submit(2, for: 2)
        fast.finish { fastDone.signal() }
        expect(fastDone.wait(timeout: .now() + 2) == .success, "one stalled app blocked its neighbour")
        slow.finish(cancel: true) { slowDone.signal() }
        release.signal()
        expect(slowDone.wait(timeout: .now() + 2) == .success, "slow app cleanup timed out")
    }
}
