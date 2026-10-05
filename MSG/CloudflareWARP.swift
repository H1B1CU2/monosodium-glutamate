import Foundation

/// Controls the installed WARP client. Public methods and callbacks run on
/// the main thread; CLI work is serialized off the UI/event-tap thread.
final class CloudflareWARP {
    static let shared = CloudflareWARP()

    enum State: Equatable {
        case unknown, unavailable, disconnected, connecting, connected, disconnecting, failed

        static func parse(_ data: Data) -> State? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let name = object["status"] as? String
                ?? (object["status"] as? [String: Any])?.keys.first
            switch name {
            case "Connected": return .connected
            case "Disconnected": return .disconnected
            case "Connecting": return .connecting
            case "Disconnecting": return .disconnecting
            case "FailedToConnect", "UnableToConnect": return .failed
            default: return nil
            }
        }

        var toggleCommand: String? {
            switch self {
            case .connected, .connecting: return "disconnect"
            case .disconnected, .failed: return "connect"
            case .unknown, .unavailable, .disconnecting: return nil
            }
        }
    }

    enum CommandError: LocalizedError {
        case missing, failed(String), unknownStatus

        var errorDescription: String? {
            switch self {
            case .missing: return "Install Cloudflare WARP to use this key."
            case .failed(let message): return message.isEmpty ? "Cloudflare WARP did not respond." : message
            case .unknownStatus: return "Could not read the WARP connection status. Open Cloudflare WARP and check its connection."
            }
        }
    }

    typealias Command = ([String]) throws -> Data
    private let command: Command
    private let queue = DispatchQueue(label: "MSG.CloudflareWARP", qos: .userInitiated)
    private var reading = false
    private(set) var commandInFlight = false
    private(set) var state: State = .unknown
    var onChange: (() -> Void)?
    var onToggleFailure: ((String) -> Void)?
    private var observers: [() -> Void] = []

    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }

    private func notify() {
        onChange?()
        observers.forEach { $0() }
    }

    init(command: @escaping Command = { try CloudflareWARP.runCommand($0) }) {
        self.command = command
    }

    func refresh() {
        guard !reading, !commandInFlight else { return }
        reading = true
        queue.async { [self] in
            let result = Result { try readState() }
            DispatchQueue.main.async { [self] in
                reading = false
                // A key press queued a fresh read behind this one. Let that
                // operation own the state, rather than publishing an old poll.
                guard !commandInFlight else { return }
                apply(result)
            }
        }
    }

    func toggle() {
        guard !commandInFlight else { return }
        commandInFlight = true
        notify()
        queue.async { [self] in
            let result = Result { () throws -> State in
                // Read at the press, since the user can also toggle WARP in
                // its own menu. Never decide from the strip's cached dot.
                let current = try readState()
                guard let verb = current.toggleCommand else { return current }
                _ = try command([verb])
                return verb == "connect" ? .connecting : .disconnecting
            }
            DispatchQueue.main.async { [self] in
                commandInFlight = false
                apply(result)
                if case .failure(let error) = result {
                    onToggleFailure?(error.localizedDescription)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
                }
            }
        }
    }

    private func readState() throws -> State {
        guard let state = State.parse(try command(["--json", "status"])) else { throw CommandError.unknownStatus }
        return state
    }

    private func apply(_ result: Result<State, Error>) {
        switch result {
        case .success(let next): state = next
        case .failure(CommandError.missing): state = .unavailable
        case .failure: state = .failed
        }
        notify()
    }

    static var executableURL: URL? {
        ["/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli",
         "/usr/local/bin/warp-cli", "/opt/homebrew/bin/warp-cli"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func runCommand(_ arguments: [String], executable: URL? = executableURL,
                           timeout: TimeInterval = 3) throws -> Data {
        guard let executable else { throw CommandError.missing }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while running, including stderr, so a verbose daemon failure
        // cannot fill a pipe and leave the key waiting forever.
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CommandError.failed(message)
        }
        return data
    }
}
