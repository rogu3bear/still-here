import Darwin
import Foundation
import Synchronization
import Testing
@testable import StillHereCore

final class FakeSignalSystem: SignalSystem {
    struct State {
        var lookup: ProcessLookup
        var alive = true
        var sendResult: Int32 = 0
        var sent: [Int32] = []
        var dieOnSignal = true
        var lookupAfterSignal: ProcessLookup?
        var onLookup: (@Sendable () -> Void)?
    }

    let state: Mutex<State>
    let ownPID: Int32 = 4_242
    let ownUID: UInt32 = 501

    init(start: Date, name: String = "node", uid: UInt32 = 501) {
        state = Mutex(State(lookup: .found(LiveProcess(startTime: start, name: name, uid: uid))))
    }

    init(lookup: ProcessLookup) { state = Mutex(State(lookup: lookup)) }

    var sent: [Int32] { state.withLock { $0.sent } }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        state.withLock { state in
            state.sent.append(signal)
            if state.sendResult == 0 {
                if state.dieOnSignal { state.alive = false }
                if let lookup = state.lookupAfterSignal { state.lookup = lookup }
            }
            return state.sendResult
        }
    }

    func isAlive(_ pid: Int32) -> Bool { state.withLock { $0.alive } }
    func lookup(_ pid: Int32) -> ProcessLookup {
        let (lookup, onLookup) = state.withLock { ($0.alive ? $0.lookup : .notFound, $0.onLookup) }
        onLookup?()
        return lookup
    }
}

@Suite struct ProcessSignallerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000.123456)

    func target(pid: Int32 = 500, name: String = "node", approximate: Bool = false) -> SignalTarget {
        SignalTarget(pid: pid, name: name, startTime: start, approximateStart: approximate)
    }

    @Test func startTimeMismatchSendsNothing() {
        let system = FakeSignalSystem(start: start.addingTimeInterval(5))
        let signaller = ProcessSignaller(system: system)
        #expect(signaller.terminate(target()) == .pidReused)
        #expect(signaller.forceKill(target()) == .pidReused)
        #expect(system.sent.isEmpty)
    }

    @Test func nameMismatchSendsNothing() {
        let system = FakeSignalSystem(start: start, name: "sshd")
        let signaller = ProcessSignaller(system: system)
        #expect(signaller.verify(target()) == .reused)
        #expect(signaller.terminate(target()) == .pidReused)
        #expect(signaller.forceKill(target()) == .pidReused)
        #expect(system.sent.isEmpty)
    }

    @Test func truncatedNamesStillMatch() {
        #expect(ProcessSignaller.namesMatch("Code Helper (Pl", "Code Helper (Plugin)"))
        #expect(ProcessSignaller.namesMatch("node", "node"))
        #expect(!ProcessSignaller.namesMatch("no", "node"))
        #expect(!ProcessSignaller.namesMatch("python3", "python3.13"))
    }

    @Test func terminateSendsOnlySIGTERM() {
        let system = FakeSignalSystem(start: start)
        #expect(ProcessSignaller(system: system).terminate(target()) == .sent)
        #expect(system.sent == [SIGTERM])
    }

    @Test func forceKillSendsSIGKILLOnlyWhenCalled() {
        let system = FakeSignalSystem(start: start)
        #expect(ProcessSignaller(system: system).forceKill(target()) == .sent)
        #expect(system.sent == [SIGKILL])
    }

    @Test func approximateStartTimeAllowsSecondResolution() {
        let system = FakeSignalSystem(start: start.addingTimeInterval(1.2))
        let signaller = ProcessSignaller(system: system)
        #expect(signaller.terminate(target()) == .pidReused)
        #expect(signaller.terminate(target(approximate: true)) == .sent)
    }

    @Test func lookupAndSendErrorsAreReported() {
        #expect(ProcessSignaller(system: FakeSignalSystem(lookup: .notFound)).terminate(target()) == .notFound)
        #expect(ProcessSignaller(system: FakeSignalSystem(lookup: .denied)).terminate(target()) == .permissionDenied)
        let unavailable = FakeSignalSystem(lookup: .failed(errno: EIO))
        let signaller = ProcessSignaller(system: unavailable)
        #expect(signaller.verify(target()) == .failed(errno: EIO))
        #expect(signaller.terminate(target()) == .failed(errno: EIO))
        #expect(unavailable.sent.isEmpty)
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.sendResult = EPERM }
        #expect(ProcessSignaller(system: system).terminate(target()) == .permissionDenied)
        system.state.withLock { $0.sendResult = EINVAL }
        #expect(ProcessSignaller(system: system).terminate(target()) == .failed(errno: EINVAL))
    }

    @Test func refusesLaunchdInvalidAndOwnPIDs() {
        let system = FakeSignalSystem(start: start)
        let signaller = ProcessSignaller(system: system)
        #expect(signaller.terminate(target(pid: 1)) == .refused(.protectedPID))
        #expect(signaller.forceKill(target(pid: 0)) == .refused(.protectedPID))
        #expect(signaller.forceKill(target(pid: -500)) == .refused(.protectedPID))
        #expect(signaller.terminate(target(pid: system.ownPID)) == .refused(.ownProcess))
        #expect(system.sent.isEmpty)
    }

    @Test func refusesOtherUsersProcesses() {
        let system = FakeSignalSystem(start: start, uid: 0)
        let signaller = ProcessSignaller(system: system)
        #expect(signaller.terminate(target()) == .refused(.otherUser))
        #expect(signaller.forceKill(target()) == .refused(.otherUser))
        #expect(system.sent.isEmpty)
    }

    @Test func waitForExitConfirmsTheOriginalIdentityIsGone() async {
        let system = FakeSignalSystem(start: start)
        let signaller = ProcessSignaller(system: system)
        _ = signaller.terminate(target())
        let result = await signaller.waitForExit(target(), timeout: .milliseconds(200), pollInterval: .milliseconds(10))
        #expect(result == .stopped)
    }

    @Test func waitForExitTimesOutWhenProcessIgnoresSIGTERM() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.dieOnSignal = false }
        let signaller = ProcessSignaller(system: system)
        _ = signaller.terminate(target())
        let result = await signaller.waitForExit(target(), timeout: .milliseconds(100), pollInterval: .milliseconds(10))
        #expect(result == .stillRunning)
        #expect(system.sent == [SIGTERM])
    }

    @Test func pidReuseCompletesWithoutWaitingForTheReplacementToExit() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.lookup = .found(LiveProcess(startTime: start.addingTimeInterval(10), name: "node", uid: system.ownUID)) }
        let result = await ProcessSignaller(system: system).waitForExit(target(), timeout: .zero)
        #expect(result == .stopped)
        #expect(system.isAlive(500))
        #expect(system.sent.isEmpty)
    }

    @Test func missingIdentityCompletesEvenWhenPIDLivenessIsStale() async {
        let system = FakeSignalSystem(lookup: .notFound)
        #expect(system.isAlive(500))
        #expect(await ProcessSignaller(system: system).waitForExit(target(), timeout: .zero) == .stopped)
    }

    @Test func deniedAndRefusedCompletionKeepTheirFailureMeaning() async {
        let denied = ProcessSignaller(system: FakeSignalSystem(lookup: .denied))
        #expect(await denied.waitForExit(target(), timeout: .zero) == .denied)
        let other = ProcessSignaller(system: FakeSignalSystem(start: start, uid: 0))
        #expect(await other.waitForExit(target(), timeout: .zero) == .refused(.otherUser))
    }

    @Test func lookupFailureDoesNotBecomeSuccessfulCompletion() async {
        let system = FakeSignalSystem(lookup: .failed(errno: EIO))
        let result = await ProcessSignaller(system: system).waitForExit(target(), timeout: .zero)
        #expect(result == .failed(errno: EIO))
        #expect(system.sent.isEmpty)
    }

    @Test func cancellationInterruptsCompletionWithoutReportingStopped() async {
        let system = FakeSignalSystem(lookup: .notFound)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProcessSignaller(system: system).waitForExit(target(), timeout: .seconds(30))
        }
        #expect(await task.value == .cancelled)
        #expect(system.sent.isEmpty)
    }

    @Test func cancellationInterruptsAnActiveWait() async {
        let system = FakeSignalSystem(start: start)
        let (observations, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        system.state.withLock { $0.onLookup = { continuation.yield(()) } }
        let task = Task {
            await ProcessSignaller(system: system).waitForExit(
                target(), timeout: .seconds(30), pollInterval: .seconds(30)
            )
        }
        var iterator = observations.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(system.sent.isEmpty)
    }

    @Test func darwinSystemSeesThisProcess() {
        let system = DarwinSignalSystem()
        let pid = getpid()
        #expect(system.isAlive(pid))
        #expect(system.ownPID == pid)
        #expect(system.ownUID == getuid())
        guard case .found(let live) = system.lookup(pid) else {
            Issue.record("no identity for own pid")
            return
        }
        #expect(live.startTime < Date())
        #expect(live.uid == getuid())
        #expect(!live.name.isEmpty)
        #expect(system.send(0, to: pid) == 0)
        // The signaller never targets its own process, even with a matching identity.
        let me = SignalTarget(pid: pid, name: live.name, startTime: live.startTime)
        #expect(ProcessSignaller(system: system).verify(me) == .refused(.ownProcess))
    }
}
