import Darwin
import Foundation
import Synchronization
import Testing
import StillHereCore
@testable import StillHereApp

/// Each case feeds the same kernel observations to both adapters; no real PID is signalled.
nonisolated enum CompletionScenario: CaseIterable, Sendable {
    case deniedAfterTERM
    case refusedAfterTERM
    case reusedAfterTERM
    case reusedAfterKILL
    case reusedBeforeKILL
    case goneAfterKILL
    case sameIdentitySurvivesTERM
    case sameIdentitySurvivesKILL
    case replacementListenerOnSamePort
    case deniedAfterKILL
    case refusedAfterKILL
    case cancelledAfterTERM
    case cancelledAfterKILL

    var expectsKILL: Bool {
        switch self {
        case .reusedAfterKILL, .goneAfterKILL, .sameIdentitySurvivesKILL, .deniedAfterKILL, .refusedAfterKILL, .cancelledAfterKILL: true
        default: false
        }
    }

    var cancellationSignal: Int32? {
        switch self {
        case .cancelledAfterTERM: SIGTERM
        case .cancelledAfterKILL: SIGKILL
        default: nil
        }
    }

    func expected(pid: Int32) -> ServerStopper.Result {
        switch self {
        case .deniedAfterTERM, .deniedAfterKILL:
            .failed("PID \(pid) can no longer be inspected; it may still be running")
        case .refusedAfterTERM, .refusedAfterKILL:
            .failed("PID \(pid) verification was refused (belongs to another user); it may still be running")
        case .reusedAfterTERM, .reusedBeforeKILL, .replacementListenerOnSamePort: .stopped(killed: false)
        case .reusedAfterKILL, .goneAfterKILL: .stopped(killed: true)
        case .sameIdentitySurvivesTERM: .stillRunning(after: .terminate)
        case .sameIdentitySurvivesKILL: .stillRunning(after: .kill)
        case .cancelledAfterTERM, .cancelledAfterKILL: .cancelled
        }
    }
}

nonisolated private final class CompletionSignalSystem: SignalSystem {
    struct State {
        var signals: [Int32] = []
        var pids: [Int32] = []
        var termLookups = 0
        var cancel: (@Sendable () -> Void)?
    }

    let ownPID: Int32 = 4_242
    let ownUID: UInt32 = 77
    private let scenario: CompletionScenario
    private let target: SignalTarget
    private let detector: FakeServerDetector
    private let replacement: ServerEntry
    private let state = Mutex(State())

    init(_ scenario: CompletionScenario, entry: ServerEntry, detector: FakeServerDetector, replacement: ServerEntry) {
        self.scenario = scenario
        target = SignalTarget(entry)!
        self.detector = detector
        self.replacement = replacement
    }

    var signals: [Int32] { state.withLock { $0.signals } }
    var signalledPIDs: [Int32] { state.withLock { $0.pids } }
    func cancelOnSignal(_ cancel: @escaping @Sendable () -> Void) { state.withLock { $0.cancel = cancel } }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        let cancel = state.withLock { state in
            state.signals.append(signal)
            state.pids.append(pid)
            return state.cancel
        }
        if scenario == .replacementListenerOnSamePort {
            detector.scenario.entries = [replacement]
        }
        if scenario.cancellationSignal == signal { cancel?() }
        return 0
    }

    // Reuse deliberately keeps the numeric PID alive. Completion must consult identity.
    func isAlive(_ pid: Int32) -> Bool { scenario != .replacementListenerOnSamePort }

    func lookup(_ pid: Int32) -> ProcessLookup {
        let (lastSignal, termLookups) = state.withLock { state in
            if state.signals.last == SIGTERM { state.termLookups += 1 }
            return (state.signals.last, state.termLookups)
        }
        var live = LiveProcess(startTime: target.startTime, name: target.name, uid: ownUID)
        guard let lastSignal else { return .found(live) }
        switch scenario {
        case .deniedAfterTERM: return .denied
        case .refusedAfterTERM: live.uid += 1
        case .reusedAfterTERM: live.startTime += 60
        case .reusedBeforeKILL where termLookups > 1: live.startTime += 60
        case .replacementListenerOnSamePort: return .notFound
        case .reusedAfterKILL where lastSignal == SIGKILL: live.startTime += 60
        case .goneAfterKILL where lastSignal == SIGKILL: return .notFound
        case .deniedAfterKILL where lastSignal == SIGKILL: return .denied
        case .refusedAfterKILL where lastSignal == SIGKILL: live.uid += 1
        default: break
        }
        return .found(live)
    }
}

@Suite struct StopAdapterCompletionTests {
    let entry = SampleServers.flask

    private var replacement: ServerEntry {
        var value = entry
        value.rootPID = 51_000
        value.process?.pid = value.rootPID
        let replacementStart = value.process!.startTime!.addingTimeInterval(60)
        value.process?.startTime = replacementStart
        return value
    }

    private func system(_ scenario: CompletionScenario) -> (CompletionSignalSystem, FakeServerDetector) {
        let detector = FakeServerDetector(scenario: .init(entries: [entry]))
        return (CompletionSignalSystem(scenario, entry: entry, detector: detector, replacement: replacement), detector)
    }

    @Test(arguments: CompletionScenario.allCases)
    func nativeAndHeadlessReturnTheSameCoreOutcome(_ scenario: CompletionScenario) async throws {
        let (headlessSystem, headlessDetector) = system(scenario)
        let stopper = ServerStopper(signaller: ProcessSignaller(system: headlessSystem), exitTimeout: .zero)
        let escalate = scenario != .sameIdentitySurvivesTERM
        let headlessTask = Task { await stopper.stop(entry, force: escalate) }
        headlessSystem.cancelOnSignal { headlessTask.cancel() }
        let headless = await headlessTask.value

        let (nativeSystem, nativeDetector) = system(scenario)
        let flow = StopFlow(signaller: ProcessSignaller(system: nativeSystem), exitTimeout: .zero)
        var refreshes = 0
        flow.onStopped = { refreshes += 1 }
        flow.requestStop(entry)
        #expect(nativeSystem.signals.isEmpty)
        let nativeTask = Task {
            let term = await flow.confirmTerminate(entry)
            if escalate, term == .stillRunning(after: .terminate) {
                #expect(nativeSystem.signals == [SIGTERM])
                return await flow.confirmForceKill(entry)
            }
            return term
        }
        nativeSystem.cancelOnSignal { nativeTask.cancel() }
        let native = try #require(await nativeTask.value)

        #expect(native == headless)
        #expect(native == scenario.expected(pid: entry.rootPID))
        let expectedSignals: [Int32] = scenario.expectsKILL ? [SIGTERM, SIGKILL] : [SIGTERM]
        #expect(nativeSystem.signals == expectedSignals)
        #expect(headlessSystem.signals == expectedSignals)
        #expect(nativeSystem.signalledPIDs.allSatisfy { $0 == entry.rootPID })
        #expect(headlessSystem.signalledPIDs.allSatisfy { $0 == entry.rootPID })
        #expect(refreshes == (native.succeeded ? 1 : 0))

        if native.succeeded {
            #expect(flow.phase(for: entry) == nil)
        } else if native == .stillRunning(after: .terminate) {
            guard case .stillRunning(let target) = flow.phase(for: entry) else {
                Issue.record("Only a verified TERM survivor may receive a KILL offer"); return
            }
            #expect(target == SignalTarget(entry))
            flow.dismiss(entry)
            #expect(flow.phase(for: entry) == nil)
            #expect(nativeSystem.signals == [SIGTERM])
        } else {
            guard case .failed(let message) = flow.phase(for: entry) else {
                Issue.record("Unresolved completion must retain a visible error"); return
            }
            #expect(message == native.message)
            // Failure/cancellation and a KILL survivor cannot enable another escalation.
            #expect(await flow.confirmForceKill(entry) == nil)
            #expect(nativeSystem.signals == expectedSignals)
        }

        if scenario == .replacementListenerOnSamePort {
            #expect(nativeDetector.scenario.entries == [replacement])
            #expect(headlessDetector.scenario.entries == [replacement])
            #expect(flow.phase(for: replacement) == nil)
            #expect(await flow.confirmForceKill(replacement) == nil)
            #expect(nativeSystem.signals == [SIGTERM])
        }
    }

    @Test func alreadyCancelledAdaptersDoNotSignalOrComplete() async {
        let (system, _) = system(.sameIdentitySurvivesKILL)
        let stopper = ServerStopper(signaller: ProcessSignaller(system: system), exitTimeout: .zero)
        let headlessTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await stopper.stop(entry, force: true)
        }
        #expect(await headlessTask.value == .cancelled)

        let flow = StopFlow(signaller: ProcessSignaller(system: system), exitTimeout: .zero)
        var refreshes = 0
        flow.onStopped = { refreshes += 1 }
        flow.requestStop(entry)
        let nativeTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await flow.confirmTerminate(entry)
        }
        #expect(await nativeTask.value == .cancelled)
        #expect(system.signals.isEmpty)
        #expect(refreshes == 0)
        guard case .failed = flow.phase(for: entry) else { Issue.record("expected retained cancellation"); return }
    }
}
