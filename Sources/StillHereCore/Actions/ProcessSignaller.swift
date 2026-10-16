import Darwin
import Foundation

/// What the kernel currently reports for a PID.
public struct LiveProcess: Sendable, Hashable {
    public var startTime: Date
    public var name: String
    public var uid: UInt32

    public init(startTime: Date, name: String, uid: UInt32) {
        self.startTime = startTime
        self.name = name
        self.uid = uid
    }
}

/// Result of a live process lookup.
public enum ProcessLookup: Sendable, Hashable {
    case found(LiveProcess)
    case notFound
    case denied
    case failed(errno: Int32)
}

/// The kernel operations the signaller needs; injectable so tests never signal anything.
public protocol SignalSystem: Sendable {
    /// Sends `signal` to `pid`; returns 0 on success or the `errno` value.
    func send(_ signal: Int32, to pid: Int32) -> Int32
    func isAlive(_ pid: Int32) -> Bool
    func lookup(_ pid: Int32) -> ProcessLookup
    /// This app's own PID, which is never signalled.
    var ownPID: Int32 { get }
    /// The current user; processes owned by anyone else are never signalled.
    var ownUID: UInt32 { get }
}

extension SignalSystem {
    public var ownPID: Int32 { getpid() }
    public var ownUID: UInt32 { getuid() }
}

/// The exact process a signal is aimed at: PID plus the start time and name seen when it
/// was listed, so a reused PID is never signalled.
public struct SignalTarget: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var startTime: Date
    /// True when `startTime` came from `ps etime` (second resolution).
    public var approximateStart: Bool

    public init(pid: Int32, name: String, startTime: Date, approximateStart: Bool = false) {
        self.pid = pid
        self.name = name
        self.startTime = startTime
        self.approximateStart = approximateStart
    }

    /// Nil when the entry's start time is unknown: such a process is never signalled.
    public init?(_ entry: ServerEntry) {
        guard let start = entry.process?.startTime else { return nil }
        self.init(
            pid: entry.rootPID,
            name: entry.processName,
            startTime: start,
            approximateStart: entry.process?.startTimeIsApproximate ?? false
        )
    }
}

/// Why a signal was refused before anything was sent.
public enum SignalRefusal: Sendable, Hashable {
    /// PID 0, launchd (1) or a negative (process group) PID.
    case protectedPID
    case ownProcess
    case otherUser
}

/// Whether a PID still names the listed process.
public enum TargetVerification: Sendable, Hashable {
    case same
    case gone
    /// The PID now belongs to a different process (start time or name changed).
    case reused
    case denied
    case failed(errno: Int32)
    case refused(SignalRefusal)
}

/// Completion of an operation on the captured process, independent of who holds its port.
public enum ProcessCompletion: Sendable, Hashable {
    /// The original identity is gone; a replacement PID or listener is left untouched.
    case stopped
    case stillRunning
    case denied
    case failed(errno: Int32)
    case refused(SignalRefusal)
    case cancelled
}

public enum SignalOutcome: Sendable, Hashable {
    case sent
    /// The PID now belongs to a different process; nothing was sent.
    case pidReused
    case notFound
    case permissionDenied
    case refused(SignalRefusal)
    case failed(errno: Int32)
}

/// Sends SIGTERM or SIGKILL to one root PID (never a process group), after proving the
/// PID still names the process that was listed and belongs to the current user.
public struct ProcessSignaller: Sendable {
    private let system: any SignalSystem

    public init(system: any SignalSystem = DarwinSignalSystem()) {
        self.system = system
    }

    public func terminate(_ target: SignalTarget) -> SignalOutcome {
        send(SIGTERM, to: target)
    }

    /// SIGKILL. Only ever sent through this explicit call.
    public func forceKill(_ target: SignalTarget) -> SignalOutcome {
        send(SIGKILL, to: target)
    }

    /// Checks, without signalling, that `target.pid` is still the listed process.
    public func verify(_ target: SignalTarget) -> TargetVerification {
        let pid = target.pid
        guard pid > 1 else { return .refused(.protectedPID) }
        guard pid != system.ownPID else { return .refused(.ownProcess) }
        switch system.lookup(pid) {
        case .notFound:
            return .gone
        case .denied:
            return .denied
        case .failed(let code):
            return .failed(errno: code)
        case .found(let live):
            // `ps etime` has one-second resolution; libproc is exact to the microsecond.
            let tolerance: TimeInterval = target.approximateStart ? 2 : 0.001
            guard abs(live.startTime.timeIntervalSince(target.startTime)) <= tolerance,
                  Self.namesMatch(live.name, target.name)
            else { return .reused }
            guard live.uid == system.ownUID else { return .refused(.otherUser) }
            return .same
        }
    }

    /// Polls the captured identity after either signal. A reused PID proves the original
    /// exited; denied/refused lookup and cancellation never imply successful completion.
    @concurrent
    public func waitForExit(
        _ target: SignalTarget,
        timeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(250)
    ) async -> ProcessCompletion {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            guard !Task.isCancelled else { return .cancelled }
            let observation = verify(target)
            guard !Task.isCancelled else { return .cancelled }
            switch observation {
            case .gone, .reused: return .stopped
            case .denied: return .denied
            case .failed(let code): return .failed(errno: code)
            case .refused(let reason): return .refused(reason)
            case .same: break
            }
            guard clock.now < deadline else { return .stillRunning }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .cancelled
            }
        }
    }

    /// Names match exactly, or one is a truncation of the other (`p_comm` keeps 16 bytes,
    /// lsof's command column fewer), as long as the shorter keeps at least 9 characters.
    static func namesMatch(_ live: String, _ expected: String) -> Bool {
        if live == expected { return true }
        let (short, long) = live.count < expected.count ? (live, expected) : (expected, live)
        return short.count >= 9 && long.hasPrefix(short)
    }

    private func send(_ signal: Int32, to target: SignalTarget) -> SignalOutcome {
        switch verify(target) {
        case .same: break
        case .gone: return .notFound
        case .reused: return .pidReused
        case .denied: return .permissionDenied
        case .failed(let code): return .failed(errno: code)
        case .refused(let reason): return .refused(reason)
        }
        switch system.send(signal, to: target.pid) {
        case 0: return .sent
        case ESRCH: return .notFound
        case EPERM: return .permissionDenied
        case let code: return .failed(errno: code)
        }
    }
}
