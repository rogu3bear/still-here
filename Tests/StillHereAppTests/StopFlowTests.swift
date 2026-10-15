import Darwin
import Foundation
import Testing
import StillHereCore
@testable import StillHereApp

@Suite struct StopFlowTests {
    let temp = TemporaryDefaults()
    let entry = SampleServers.flask

    private func setUp(fatal: Set<Int32>, start: Date? = nil) -> (ServerListModel, ScriptedSignalSystem, FakeServerDetector) {
        let detector = FakeServerDetector()
        let system = ScriptedSignalSystem(
            start: start ?? entry.process!.startTime!, name: entry.processName,
            fatalSignals: fatal, detector: detector, port: entry.port
        )
        return (ServerListModel.make(detector, defaults: temp, signalSystem: system), system, detector)
    }

    @Test func requestOnlyAsksForConfirmation() {
        let (model, system, _) = setUp(fatal: [SIGTERM])
        model.stopFlow.requestStop(entry)
        guard case .confirmTerminate(let target) = model.stopFlow.phase(for: entry) else {
            Issue.record("expected confirmation"); return
        }
        #expect(target.pid == entry.rootPID)
        #expect(system.sent.isEmpty)

        model.stopFlow.dismiss(entry)
        #expect(model.stopFlow.phase(for: entry) == nil)
        #expect(system.sent.isEmpty)
    }

    @Test func sigtermStopsTheServerAndRefreshes() async {
        let (model, system, detector) = setUp(fatal: [SIGTERM])
        await model.refresh(.manual)
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)

        #expect(system.sent == [SIGTERM])
        #expect(model.stopFlow.phase(for: entry) == nil)
        #expect(!model.servers.contains { $0.port == entry.port })
        #expect(detector.scanCount >= 2)
    }

    @Test func survivingSigtermOffersSigkillWithoutSendingIt() async {
        let (model, system, _) = setUp(fatal: [SIGKILL])
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)

        guard case .stillRunning(let target) = model.stopFlow.phase(for: entry) else {
            Issue.record("expected SIGKILL offer"); return
        }
        #expect(target.pid == entry.rootPID)
        #expect(system.sent == [SIGTERM])

        await model.stopFlow.confirmForceKill(entry)
        #expect(system.sent == [SIGTERM, SIGKILL])
        #expect(model.stopFlow.phase(for: entry) == nil)
    }

    @Test func forceKillNeedsTheStillRunningPhase() async {
        let (model, system, _) = setUp(fatal: [SIGKILL])
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmForceKill(entry)
        #expect(system.sent.isEmpty)
    }

    @Test func reusedPIDAbortsWithoutSignalling() async {
        let (model, system, _) = setUp(fatal: [SIGTERM], start: entry.process!.startTime!.addingTimeInterval(60))
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)

        #expect(system.sent.isEmpty)
        guard case .failed(let message) = model.stopFlow.phase(for: entry) else {
            Issue.record("expected failure"); return
        }
        #expect(message.contains("different process"))
    }

    @Test func unknownStartTimeIsNeverSignalled() {
        let (model, system, _) = setUp(fatal: [SIGTERM])
        var unknown = entry
        unknown.process?.startTime = nil
        model.stopFlow.requestStop(unknown)
        guard case .failed = model.stopFlow.phase(for: unknown) else {
            Issue.record("expected failure"); return
        }
        #expect(system.sent.isEmpty)
    }

    @Test func replacementListenerIsNeverOfferedSigkill() async {
        let (model, system, detector) = setUp(fatal: [SIGTERM])
        var other = SampleServers.flask
        other.rootPID = 51_000
        other.process?.pid = 51_000
        other.process?.name = "nc"
        other.command = "nc"
        system.update { $0.successor = other }
        await model.refresh(.manual)
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)

        #expect(system.sent == [SIGTERM])
        #expect(model.stopFlow.phases.isEmpty)
        #expect(model.servers.contains { $0.rootPID == 51_000 })
        #expect(model.stopFlow.phase(for: other) == nil)
        await model.stopFlow.confirmForceKill(other)
        #expect(system.sent == [SIGTERM])
        #expect(detector.scanCount >= 2)
    }

    @Test func survivorWithDifferentIdentityIsNotOfferedSigkill() async {
        let (model, system, _) = setUp(fatal: [])
        model.stopFlow.requestStop(entry)
        // After SIGTERM the PID starts naming a different process (reuse); the port stays held.
        let task = Task { await model.stopFlow.confirmTerminate(entry) }
        try? await Task.sleep(for: .milliseconds(50))
        system.update { $0.start = $0.start.addingTimeInterval(30) }
        _ = await task.value
        #expect(system.sent == [SIGTERM])
        #expect(model.stopFlow.phase(for: entry) == nil)
    }

    @Test func renamedProcessIsNotSignalled() async {
        let (model, system, _) = setUp(fatal: [SIGTERM])
        system.update { $0.name = "sshd" }
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)
        #expect(system.sent.isEmpty)
        guard case .failed = model.stopFlow.phase(for: entry) else { Issue.record("expected failure"); return }
    }

    @Test func otherUsersProcessIsRefused() async {
        let (model, system, _) = setUp(fatal: [SIGTERM])
        system.update { $0.uid = 0 }
        model.stopFlow.requestStop(entry)
        await model.stopFlow.confirmTerminate(entry)
        #expect(system.sent.isEmpty)
        guard case .failed(let message) = model.stopFlow.phase(for: entry) else { Issue.record("expected failure"); return }
        #expect(message.contains("another user"))
    }

    @Test func hiddenSystemEntriesCannotBeStopped() {
        let (model, system, _) = setUp(fatal: [SIGTERM])
        let protected = SampleServers.controlCenter
        #expect(!protected.isStoppable)
        #expect(SampleServers.postgres.isStoppable)
        model.stopFlow.requestStop(protected)
        guard case .failed = model.stopFlow.phase(for: protected) else { Issue.record("expected refusal"); return }

        // Shown because Settings turned its hide rule off: still never stopped.
        var shown = protected
        shown.hiddenReason = nil
        shown.protection = .system
        #expect(!shown.isStoppable)
        model.stopFlow.requestStop(shown)
        guard case .failed = model.stopFlow.phase(for: shown) else { Issue.record("expected refusal"); return }
        #expect(system.sent.isEmpty)
    }

    @Test func phasesArePrunedWhenTheRowChangesHands() async {
        let (model, _, detector) = setUp(fatal: [SIGTERM])
        await model.refresh(.manual)
        model.stopFlow.requestStop(entry)
        #expect(model.stopFlow.phase(for: entry) != nil)

        var restarted = entry
        restarted.process?.startTime = entry.process!.startTime!.addingTimeInterval(10)
        var scenario = detector.scenario
        scenario.entries = scenario.entries.map { $0.port == entry.port ? restarted : $0 }
        detector.scenario = scenario
        await model.refresh(.timer)

        #expect(model.stopFlow.phases.isEmpty)
        #expect(model.stopFlow.phase(for: restarted) == nil)
    }
}
