import Darwin
import Foundation
import Synchronization
import Testing
import StillHereCore
@testable import StillHereApp

private nonisolated final class RecoveringFlushSource: FlushSource {
    private let attempts = Mutex(0)
    private let entries: [FlushCandidate]

    init(_ entries: [FlushCandidate]) { self.entries = entries }

    func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] {
        let attempt = attempts.withLock { value in value += 1; return value }
        guard attempt > 1 else { throw FlushScanError.ownershipUnavailable }
        return entries
    }
}

@Suite struct FlushFlowTests {
    var candidate: FlushCandidate {
        FlushCandidate(target: SignalTarget(pid: 100, name: "node", startTime: Date()), directory: "/demo", reason: .orphaned)
    }

    @Test func requestOnlyReviewsAndCancelClearsThePlan() async {
        let flow = FlushFlow(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: InertSignalSystem()))
        await flow.request(config: .defaults)
        guard case .confirming(let entries) = flow.phase else { Issue.record("Missing review"); return }
        #expect(entries.count == 1)
        flow.dismiss()
        #expect(flow.phase == .idle)
        await flow.confirm(config: .defaults)
        #expect(flow.phase == .idle)
    }

    @Test func confirmRecordsCompletionAndRefreshesOnlyAfterItFinishes() async {
        let flow = FlushFlow(source: FixedFlushSource([candidate]), signaller: ProcessSignaller(system: InertSignalSystem()))
        var refreshes = 0
        flow.onFinished = { refreshes += 1 }
        await flow.request(config: .defaults)
        #expect(refreshes == 0)
        await flow.confirm(config: .defaults)
        guard case .finished(let report) = flow.phase else { Issue.record("Missing completion"); return }
        #expect(report.stopped == 1)
        #expect(refreshes == 1)
    }

    @Test func emptyPlanCannotStartAnOperation() async {
        let flow = FlushFlow(source: FixedFlushSource(), signaller: ProcessSignaller(system: InertSignalSystem()))
        await flow.request(config: .defaults)
        await flow.confirm(config: .defaults)
        #expect(flow.phase == .confirming([]))
    }

    @Test func failedReviewCanBeDismissedAndRetriedWithoutStoppingAnythingEarly() async {
        let entry = candidate
        let source = RecoveringFlushSource([entry])
        let system = ScriptedSignalSystem(
            start: entry.target.startTime, name: entry.target.name, fatalSignals: [SIGTERM],
            detector: FakeServerDetector(scenario: .init(entries: [])), port: 3000
        )
        let flow = FlushFlow(source: source, signaller: ProcessSignaller(system: system))

        await flow.request(config: .defaults)
        guard case .failed(let message) = flow.phase else { Issue.record("Missing scan failure"); return }
        #expect(message == FlushScanError.ownershipUnavailable.localizedDescription)
        #expect(!flow.isBusy)
        await flow.confirm(config: .defaults)
        #expect(system.sent.isEmpty)

        flow.dismiss()
        #expect(flow.phase == .idle)
        await flow.request(config: .defaults)
        guard case .confirming(let entries) = flow.phase else { Issue.record("Missing fresh review"); return }
        #expect(entries.map(\.id) == [entry.id])
        #expect(system.sent.isEmpty)

        await flow.confirm(config: .defaults)
        guard case .finished(let report) = flow.phase else { Issue.record("Missing completion after recovery"); return }
        #expect(report.stopped == 1)
        #expect(report.unresolved == 0)
        #expect(report.error == nil)
        #expect(system.sent == [SIGTERM])
    }
}
