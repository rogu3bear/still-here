import Foundation
import Testing
import StillHereCore
@testable import StillHereApp

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
}
