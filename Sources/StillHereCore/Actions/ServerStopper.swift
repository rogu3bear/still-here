import Foundation

/// Signals and reconciles one captured process identity. The CLI/MCP use `stop` for
/// optional escalation; the native menu confirms each signal through the same operations.
public struct ServerStopper: Sendable {
    public enum Signal: Sendable, Hashable {
        case terminate
        case kill
    }

    public enum Result: Sendable, Hashable {
        case stopped(killed: Bool)
        /// The captured identity remains after the specified signal's deadline.
        case stillRunning(after: Signal)
        case notStoppable(String)
        case failed(String)
        case cancelled

        public var succeeded: Bool {
            if case .stopped = self { return true }
            return false
        }

        public var message: String {
            switch self {
            case .stopped(let killed): killed ? "stopped with SIGKILL" : "stopped"
            case .stillRunning(after: .terminate): "still running after SIGTERM; retry with force to send SIGKILL"
            case .stillRunning(after: .kill): "still running after SIGKILL"
            case .notStoppable(let reason), .failed(let reason): reason
            case .cancelled: "stop cancelled; the process may still be running"
            }
        }
    }

    private let signaller: ProcessSignaller
    private let exitTimeout: Duration
    private let pollInterval: Duration

    public init(
        signaller: ProcessSignaller = ProcessSignaller(),
        exitTimeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.signaller = signaller
        self.exitTimeout = exitTimeout
        self.pollInterval = pollInterval
    }

    public func stop(_ entry: ServerEntry, force: Bool) async -> Result {
        guard entry.isStoppable else {
            return .notStoppable("system, daemon or app-helper process; not stopped")
        }
        guard let target = SignalTarget(entry) else {
            return .notStoppable("start time unknown, so the process can't be verified; not stopped")
        }
        let result = await terminate(target)
        guard force, result == .stillRunning(after: .terminate) else { return result }
        return await forceKill(target)
    }

    /// The caller supplies the target already captured from a stoppable entry.
    public func terminate(_ target: SignalTarget) async -> Result {
        await signalAndWait(.terminate, target: target)
    }

    /// Explicit escalation for the same target; this never resolves a new target by port.
    public func forceKill(_ target: SignalTarget) async -> Result {
        await signalAndWait(.kill, target: target)
    }

    @concurrent
    private func signalAndWait(_ signal: Signal, target: SignalTarget) async -> Result {
        guard !Task.isCancelled else { return .cancelled }
        let outcome = signal == .kill ? signaller.forceKill(target) : signaller.terminate(target)
        guard !Task.isCancelled else { return .cancelled }
        // The original can exit between TERM completion and the explicit KILL check.
        // That check must neither signal the replacement nor call it a failed Stop.
        if signal == .kill, outcome == .pidReused || outcome == .notFound {
            return .stopped(killed: false)
        }
        if let failure = Self.failure(outcome, pid: target.pid) { return failure }
        switch await signaller.waitForExit(target, timeout: exitTimeout, pollInterval: pollInterval) {
        case .stopped: return .stopped(killed: signal == .kill && outcome == .sent)
        case .stillRunning: return .stillRunning(after: signal)
        case .denied: return .failed("PID \(target.pid) can no longer be inspected; it may still be running")
        case .failed(let code):
            return .failed("couldn't verify PID \(target.pid): \(String(cString: strerror(code))); it may still be running")
        case .refused(let reason):
            return .failed("PID \(target.pid) verification was refused (\(Self.refusalDescription(reason))); it may still be running")
        case .cancelled: return .cancelled
        }
    }

    private static func refusalDescription(_ reason: SignalRefusal) -> String {
        switch reason {
        case .protectedPID: "protected process"
        case .ownProcess: "stillhere itself"
        case .otherUser: "belongs to another user"
        }
    }

    /// nil when the signal was sent (or the process had already exited).
    static func failure(_ outcome: SignalOutcome, pid: Int32) -> Result? {
        switch outcome {
        case .sent, .notFound: nil
        case .pidReused: .failed("PID \(pid) now belongs to a different process; nothing was sent")
        case .permissionDenied: .failed("permission denied signalling PID \(pid)")
        case .refused(.protectedPID): .notStoppable("PID \(pid) is protected; nothing was sent")
        case .refused(.ownProcess): .notStoppable("PID \(pid) is stillhere itself; nothing was sent")
        case .refused(.otherUser): .notStoppable("PID \(pid) belongs to another user; nothing was sent")
        case .failed(let code): .failed("couldn't signal PID \(pid): \(String(cString: strerror(code)))")
        }
    }
}
