import Foundation
import Observation
import StillHereCore

/// Per-process stop state machine:
/// confirmTerminate -> terminating -> (gone | stillRunning) -> killing -> (gone | stillRunning).
/// Phases are keyed by the row's process identity (port, PID, start time), so a phase never
/// carries over to a different process on the same port, and phases whose row disappeared
/// are pruned after each scan. Signals go to one verified PID (never a process group).
/// SIGKILL is only offered for the exact process that received SIGTERM, and only sent
/// after the user confirms it.
@Observable
final class StopFlow {
    /// The exact process a signal is aimed at.
    typealias Target = SignalTarget
    /// A row's process identity.
    typealias Key = ServerEntry.ProbeKey

    enum Phase: Hashable {
        case confirmTerminate(Target)
        case terminating(Target)
        /// The same process is still running after SIGTERM; offers SIGKILL for it.
        case stillRunning(Target)
        case killing(Target)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .terminating, .killing: true
            default: false
            }
        }
    }

    private(set) var phases: [Key: Phase] = [:]
    var isBusy: Bool { phases.values.contains(where: \.isBusy) }

    @ObservationIgnored private let stopper: ServerStopper
    /// Called only after core completion confirms the original identity is gone.
    @ObservationIgnored var onStopped: (() async -> Void)?

    init(
        signaller: ProcessSignaller,
        exitTimeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(250)
    ) {
        stopper = ServerStopper(signaller: signaller, exitTimeout: exitTimeout, pollInterval: pollInterval)
    }

    func phase(for entry: ServerEntry) -> Phase? { phases[entry.probeKey] }

    /// Step 1: ask for confirmation. Nothing is signalled yet.
    func requestStop(_ entry: ServerEntry) {
        let key = entry.probeKey
        guard phases[key]?.isBusy != true else { return }
        if !entry.isStoppable {
            phases[key] = .failed("\(entry.processName) is a system process; Still Here won't stop it.")
        } else if let target = Target(entry) {
            phases[key] = .confirmTerminate(target)
        } else {
            phases[key] = .failed("Can't verify the process start time, so it won't be signalled.")
        }
    }

    /// Clears a confirmation, a SIGKILL offer or an error. Ignored while a signal is in progress.
    func dismiss(_ entry: ServerEntry) {
        let key = entry.probeKey
        guard phases[key]?.isBusy != true else { return }
        phases[key] = nil
    }

    /// Drops idle phases whose row is gone or now belongs to a different process.
    func prune(keeping entries: [ServerEntry]) {
        let live = Set(entries.map(\.probeKey))
        let kept = phases.filter { live.contains($0.key) || $0.value.isBusy }
        if kept.count != phases.count { phases = kept }
    }

    /// Step 2: SIGTERM, then reconcile the captured process identity in the core.
    @discardableResult
    func confirmTerminate(_ entry: ServerEntry) async -> ServerStopper.Result? {
        let key = entry.probeKey
        guard case .confirmTerminate(let target) = phases[key] else { return nil }
        phases[key] = .terminating(target)
        return await signalAndWait(key: key, target: target, kill: false)
    }

    /// Step 3 (only after `stillRunning`): SIGKILL the same verified PID.
    @discardableResult
    func confirmForceKill(_ entry: ServerEntry) async -> ServerStopper.Result? {
        let key = entry.probeKey
        guard case .stillRunning(let target) = phases[key] else { return nil }
        phases[key] = .killing(target)
        return await signalAndWait(key: key, target: target, kill: true)
    }

    private func signalAndWait(key: Key, target: Target, kill: Bool) async -> ServerStopper.Result {
        let result = await (kill ? stopper.forceKill(target) : stopper.terminate(target))
        switch result {
        case .stopped:
            phases[key] = nil
            await onStopped?()
        case .stillRunning(after: .terminate):
            phases[key] = .stillRunning(target)
        case .stillRunning(after: .kill), .notStoppable, .failed, .cancelled:
            phases[key] = .failed(result.message)
        }
        return result
    }
}
