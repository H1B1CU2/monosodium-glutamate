import Foundation
import ApplicationServices

struct TilingFrameWritePlan: Equatable {
    let position: Bool
    let size: Bool
    var isEmpty: Bool { !position && !size }

    init(previous: CGRect?, target: CGRect) {
        position = previous.map { abs($0.minX - target.minX) >= 0.5 || abs($0.minY - target.minY) >= 0.5 } ?? true
        size = previous.map { abs($0.width - target.width) >= 0.5 || abs($0.height - target.height) >= 0.5 } ?? true
    }
}

/// A bounded, latest-target mailbox. The application queue serializes complete
/// frame pairs; replacing pending work never interrupts a pair halfway through.
/// Lifecycle hooks stay on that same queue, including cancellation cleanup.
final class TilingLatestFrameLane<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let begin: () -> Void
    private let write: (Value) -> Void
    private let settle: (Value) -> Void
    private let end: () -> Void
    private var pending: [Key: Value] = [:]
    private var order: [Key] = []
    private var latest: [Key: Value] = [:]
    private var scheduled = false
    private var closing = false
    private var cancelled = false
    private var completion: (() -> Void)?
    // Only touched on queue.
    private var began = false

    init(queue: DispatchQueue, begin: @escaping () -> Void,
         write: @escaping (Value) -> Void, settle: @escaping (Value) -> Void,
         end: @escaping () -> Void) {
        self.queue = queue
        self.begin = begin
        self.write = write
        self.settle = settle
        self.end = end
    }

    func submit(_ value: Value, for key: Key) {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        if pending[key] == nil { order.append(key) }
        pending[key] = value
        latest[key] = value
        scheduleLocked()
        lock.unlock()
    }

    func finish(cancel: Bool = false, completion: @escaping () -> Void) {
        lock.lock()
        closing = true
        cancelled = cancelled || cancel
        if cancelled { pending.removeAll(); latest.removeAll(); order.removeAll() }
        let previous = self.completion
        self.completion = { previous?(); completion() }
        scheduleLocked()
        lock.unlock()
    }

    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true
        queue.async { self.drain() }
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func drain() {
        while true {
            lock.lock()
            if let key = order.first, let value = pending.removeValue(forKey: key) {
                order.removeFirst()
                lock.unlock()
                if !isCancelled() {
                    if !began { begin(); began = true }
                    if !isCancelled() { write(value) }
                }
                continue
            }
            if closing {
                let finalValues = Array(latest.values)
                latest.removeAll()
                lock.unlock()
                for value in finalValues where !isCancelled() { settle(value) }
                if began { end(); began = false }
                lock.lock()
                let done = completion
                completion = nil
                scheduled = false
                lock.unlock()
                done?()
                return
            }
            scheduled = false
            lock.unlock()
            return
        }
    }
}

/// Main-thread coordinator; AX calls themselves run on one serial queue per PID.
/// This adopts the latest-frame/lifecycle approach used by Glide, rather than
/// pretending that two Accessibility setters are an atomic compositor update.
final class TilingFramePipeline {
    private struct Request {
        let id: CGWindowID
        let element: AXUIElement
        let frame: CGRect // AX coordinates, fixed by caller before dispatch.
    }

    private final class Driver {
        let app: AXUIElement
        var restoreEnhanced = false
        var observed: [CGWindowID: CGRect] = [:]
        private var lastAccepted: [CGWindowID: CGRect] = [:]
        private var atomicFrameSupported: [CGWindowID: Bool] = [:]
        private var configuredElements: [CGWindowID: AXUIElement] = [:]

        init(pid: pid_t) {
            app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
        }

        func begin() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success,
               (value as? NSNumber)?.boolValue == true {
                restoreEnhanced = AXUIElementSetAttributeValue(
                    app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse
                ) == .success
            }
        }

        func write(_ request: Request, force: Bool = false) {
            if configuredElements[request.id] == nil {
                AXUIElementSetMessagingTimeout(request.element, 0.1)
                configuredElements[request.id] = request.element
                var settable = DarwinBoolean(false)
                atomicFrameSupported[request.id] = AXUIElementIsAttributeSettable(
                    request.element, "AXFrame" as CFString, &settable
                ) == .success && settable.boolValue
                lastAccepted[request.id] = Self.readFrame(request.element)
            }
            let plan = TilingFrameWritePlan(previous: force ? nil : lastAccepted[request.id], target: request.frame)
            guard !plan.isEmpty else { return }
            if atomicFrameSupported[request.id] == true {
                var frame = request.frame
                if let value = AXValueCreate(.cgRect, &frame),
                   AXUIElementSetAttributeValue(request.element, "AXFrame" as CFString, value) == .success {
                    lastAccepted[request.id] = frame
                    return
                }
                // Some apps advertise this attribute but reject writes. Fall
                // back once, without repeatedly probing it during this gesture.
                atomicFrameSupported[request.id] = false
            }
            var size = request.frame.size
            var position = request.frame.origin
            guard let sizeValue = AXValueCreate(.cgSize, &size),
                  let positionValue = AXValueCreate(.cgPoint, &position) else { return }
            // No readback, diagnostics query, UI work or preference toggling
            // between the two setters. AX success is acceptance, not presentation.
            let sizeResult = plan.size
                ? AXUIElementSetAttributeValue(request.element, kAXSizeAttribute as CFString, sizeValue) : .success
            let positionResult = plan.position
                ? AXUIElementSetAttributeValue(request.element, kAXPositionAttribute as CFString, positionValue) : .success
            lastAccepted[request.id] = sizeResult == .success && positionResult == .success ? request.frame : nil
        }

        func settle(_ request: Request) {
            // Only the closing target is verified/retried. Never learn a minimum
            // from a transient frame or let a retry backlog follow the pointer.
            // WebKit/Electron windows can acknowledge the AX write, then publish
            // their preceding frame for another compositor turn. A 5ms retry
            // loop completed before that stale frame cleared, so the window only
            // tiled after the next user move. Back off for at most 260ms here.
            let retryDelays: [TimeInterval] = [0.02, 0.04, 0.08, 0.12]
            for attempt in 0...retryDelays.count {
                if let frame = Self.readFrame(request.element) {
                    observed[request.id] = frame
                    if Self.matches(frame, request.frame) { return }
                }
                guard attempt < retryDelays.count else { return }
                write(request, force: true)
                Thread.sleep(forTimeInterval: retryDelays[attempt])
            }
        }

        func end() {
            if restoreEnhanced {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                restoreEnhanced = false
            }
            for element in configuredElements.values { AXUIElementSetMessagingTimeout(element, 0) }
            configuredElements.removeAll()
        }

        private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 &&
                abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }

        private static func readFrame(_ element: AXUIElement) -> CGRect? {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element,
                [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values) == .success,
                  let array = values as? [AXValue], array.count == 2,
                  AXValueGetType(array[0]) == .cgPoint, AXValueGetType(array[1]) == .cgSize else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(array[0], .cgPoint, &point),
                  AXValueGetValue(array[1], .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
    }

    private struct Worker {
        let lane: TilingLatestFrameLane<CGWindowID, Request>
        let driver: Driver
    }
    private var queues: [pid_t: DispatchQueue] = [:]
    private var workers: [pid_t: Worker] = [:]
    private var generation: UInt64 = 0
    private let cleanupGroup = DispatchGroup()
    private(set) var isFinishing = false
    var isActive: Bool { !workers.isEmpty || isFinishing }

    func submit(id: CGWindowID, element: AXUIElement, frame: CGRect) {
        precondition(Thread.isMainThread)
        guard !isFinishing else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
        if workers[pid] == nil {
            let queue = queues[pid] ?? DispatchQueue(label: "MSG.tiling.ax.\(pid)", qos: .userInteractive)
            queues[pid] = queue
            let driver = Driver(pid: pid)
            let lane = TilingLatestFrameLane<CGWindowID, Request>(queue: queue,
                begin: { driver.begin() }, write: { driver.write($0) },
                settle: { driver.settle($0) }, end: { driver.end() })
            workers[pid] = Worker(lane: lane, driver: driver)
        }
        workers[pid]?.lane.submit(Request(id: id, element: element, frame: frame), for: id)
    }

    func finish(completion: @escaping ([CGWindowID: CGRect]) -> Void) {
        precondition(Thread.isMainThread)
        guard !isFinishing else { return }
        guard !workers.isEmpty else { completion([:]); return }
        isFinishing = true
        let closingWorkers = workers
        let token = generation
        let group = DispatchGroup()
        for worker in closingWorkers.values {
            group.enter()
            worker.lane.finish { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.generation == token else { return }
            self.workers.removeAll()
            self.isFinishing = false
            var frames: [CGWindowID: CGRect] = [:]
            for worker in closingWorkers.values {
                frames.merge(worker.driver.observed) { _, new in new }
            }
            completion(frames)
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        for worker in workers.values {
            cleanupGroup.enter()
            worker.lane.finish(cancel: true) { [cleanupGroup] in cleanupGroup.leave() }
        }
        workers.removeAll()
        isFinishing = false
        // Retain per-PID queues so a new gesture cannot race an old in-flight
        // pair or restore the enhanced-UI preference ahead of its cleanup.
    }

    /// Used only on stop/quit, never on the interactive resize path.
    func shutdown() {
        cancel()
        _ = cleanupGroup.wait(timeout: .now() + 1)
    }
}
