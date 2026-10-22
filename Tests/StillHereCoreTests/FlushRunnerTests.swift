import Darwin
import Foundation
import Synchronization
import Testing
@testable import StillHereCore

private final class SequencedFlushSource: FlushSource, Sendable {
    let snapshots: Mutex<[[FlushCandidate]]>
    init(_ values: [[FlushCandidate]]) { snapshots = Mutex(values) }
    func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] {
        snapshots.withLock { values in values.count > 1 ? values.removeFirst() : (values.first ?? []) }
    }
}

private struct FailingFlushSource: FlushSource {
    func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] { throw FlushScanError.ownershipUnavailable }
}

private final class FailingAfterFirstFlushSource: FlushSource, Sendable {
    private let calls = Mutex(0)
    private let entries: [FlushCandidate]

    init(_ entries: [FlushCandidate]) { self.entries = entries }
    var scanCount: Int { calls.withLock { $0 } }

    func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] {
        let count = calls.withLock { value in value += 1; return value }
        guard count == 1 else { throw FlushScanError.ownershipUnavailable }
        return entries
    }
}

@Suite struct FlushRunnerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var candidate: FlushCandidate {
        FlushCandidate(target: SignalTarget(pid: 100, name: "node", startTime: start), directory: "/project", reason: .orphaned)
    }

    @Test func sendsOnlyTermOnceForEachConfirmedIdentity() async {
        let system = FakeSignalSystem(start: start)
        let runner = FlushRunner(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: system))
        let report = await runner.run([candidate, candidate], config: .defaults)
        #expect(system.sent == [SIGTERM])
        #expect(report.stopped == 1)
        #expect(report.unresolved == 0)
    }

    @Test func newlyActiveAndReusedTargetsArePreservedAndNewTargetsAreNeverAdded() async {
        let system = FakeSignalSystem(start: start)
        var replacement = candidate
        replacement.target.startTime = start.addingTimeInterval(20)
        let runner = FlushRunner(source: FixedFlushSource([replacement]), signaller: ProcessSignaller(system: system))
        let report = await runner.run([candidate], config: .defaults)
        #expect(system.sent.isEmpty)
        #expect(report.preserved == 1)
        #expect(report.stopped == 0)
    }

    @Test func ownershipIsScannedAgainBeforeEveryTarget() async {
        let system = FakeSignalSystem(start: start)
        var second = candidate
        second.target.pid = 101
        let source = SequencedFlushSource([[candidate, second], []])
        let runner = FlushRunner(source: source, signaller: ProcessSignaller(system: system))
        let report = await runner.run([candidate, second], config: .defaults)
        #expect(system.sent == [SIGTERM])
        #expect(report.stopped == 1)
        #expect(report.preserved == 1)
    }

    @Test func inspectionFailureSendsNothingAndReportsTheHold() async {
        let system = FakeSignalSystem(start: start)
        let runner = FlushRunner(source: FailingFlushSource(), signaller: ProcessSignaller(system: system))
        let report = await runner.run([candidate], config: .defaults)
        #expect(system.sent.isEmpty)
        #expect(report.error != nil)
        #expect(report.stopped == 0)
    }

    @Test func ownershipFailureAfterAStopAbortsTheRemainingBatch() async {
        let system = FakeSignalSystem(start: start)
        var second = candidate
        second.target.pid = 101
        var third = candidate
        third.target.pid = 102
        let entries = [candidate, second, third]
        let source = FailingAfterFirstFlushSource(entries)
        let runner = FlushRunner(source: source, signaller: ProcessSignaller(system: system))

        let report = await runner.run(entries, config: .defaults)

        #expect(source.scanCount == 2)
        #expect(system.sent == [SIGTERM])
        #expect(report.results.map(\.candidate.id) == [candidate.id])
        #expect(report.stopped == 1)
        #expect(report.unresolved == 0)
        #expect(report.error == FlushScanError.ownershipUnavailable.localizedDescription)
    }

    @Test func permissionDeniedRemainsUnresolvedWithoutForceEscalation() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.sendResult = EPERM }
        let runner = FlushRunner(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: system))

        let report = await runner.run([candidate], config: .defaults)

        #expect(system.sent == [SIGTERM])
        #expect(system.isAlive(candidate.target.pid))
        #expect(report.stopped == 0)
        #expect(report.unresolved == 1)
        #expect(report.results.first?.result == .failed("permission denied signalling PID \(candidate.target.pid)"))
    }

    @Test func aProcessThatIgnoresTermIsUnresolvedWithoutEscalation() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.dieOnSignal = false }
        let runner = FlushRunner(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: system),
                                 exitTimeout: .milliseconds(10), pollInterval: .milliseconds(1))
        let report = await runner.run([candidate], config: .defaults)
        #expect(system.sent == [SIGTERM])
        #expect(report.unresolved == 1)
        #expect(report.results.first?.result == .stillRunning(after: .terminate))
    }

    @Test func kernelIdentityChangeAfterOwnershipScanStillSendsNothing() async {
        let system = FakeSignalSystem(start: start.addingTimeInterval(5))
        let runner = FlushRunner(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: system))
        let report = await runner.run([candidate], config: .defaults)
        #expect(system.sent.isEmpty)
        #expect(report.unresolved == 1)
    }
}
