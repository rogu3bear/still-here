import Foundation
import Synchronization
import Testing
@testable import StillHereCore

@Suite struct ServerStopperTests {
    let entry = SampleServers.vite
    var start: Date { entry.process!.startTime! }

    func stopper(_ system: FakeSignalSystem) -> ServerStopper {
        ServerStopper(
            signaller: ProcessSignaller(system: system),
            exitTimeout: .milliseconds(300)
        )
    }

    @Test func sigtermStopsAServer() async {
        let system = FakeSignalSystem(start: start)
        #expect(await stopper(system).stop(entry, force: false) == .stopped(killed: false))
        #expect(system.sent == [SIGTERM])
    }

    @Test func survivorIsNotKilledWithoutForce() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.dieOnSignal = false }
        #expect(await stopper(system).stop(entry, force: false) == .stillRunning(after: .terminate))
        #expect(system.sent == [SIGTERM])
    }

    @Test func forceSendsSigkillToTheSameSurvivor() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock { $0.dieOnSignal = false }
        let result = await stopper(system).stop(entry, force: true)
        #expect(system.sent == [SIGTERM, SIGKILL])
        #expect(result == .stillRunning(after: .kill))
    }

    @Test func uninspectableSurvivorIsNotReportedStopped() async {
        let system = FakeSignalSystem(start: start)
        system.state.withLock {
            $0.dieOnSignal = false
            $0.lookupAfterSignal = .denied
        }
        let stopper = ServerStopper(
            signaller: ProcessSignaller(system: system),
            exitTimeout: .milliseconds(300)
        )
        // Sending succeeds; the next identity lookup is denied.
        guard case .failed = await stopper.stop(entry, force: false) else { Issue.record("expected failure"); return }
    }

    @Test func protectedRowsAreNeverSignalled() async {
        let system = FakeSignalSystem(start: start)
        let result = await stopper(system).stop(SampleServers.controlCenter, force: true)
        guard case .notStoppable = result else { Issue.record("expected notStoppable, got \(result)"); return }
        // Listed because its hide rule is off, and still protected.
        var shown = SampleServers.controlCenter
        shown.hiddenReason = nil
        shown.protection = .system
        guard case .notStoppable = await stopper(system).stop(shown, force: true) else { Issue.record("expected notStoppable"); return }
        #expect(ServerReport(entry: shown, probe: nil, now: SampleServers.referenceDate).stoppable == false)
        #expect(system.sent.isEmpty)
    }

    @Test func reusedPIDIsNeverSignalled() async {
        let system = FakeSignalSystem(start: start.addingTimeInterval(60))
        guard case .failed = await stopper(system).stop(entry, force: true) else { Issue.record("expected failure"); return }
        #expect(system.sent.isEmpty)
    }
}

@Suite struct ServerQueryTests {
    let query = ServerQuery(detector: FakeServerDetector())

    @Test func rulesAreReadOnEveryScan() async throws {
        // A long-running MCP server must follow edits to the saved ignore list.
        let detector = FakeServerDetector()
        let current = Mutex(IgnoreConfiguration.defaults)
        let query = ServerQuery(detector: detector, rules: { current.withLock { $0 } })
        _ = try await query.entries()
        #expect(detector.lastConfig == .defaults)
        current.withLock { $0.processNames = ["node"] }
        _ = try await query.entries()
        #expect(detector.lastConfig?.processNames == ["node"])
    }

    @Test func hidesHiddenByDefault() async throws {
        let ports = try await query.entries().map(\.port)
        #expect(!ports.contains(5432))
        #expect(try await query.entries(.init(includeHidden: true)).map(\.port).contains(5432))
    }

    @Test func filtersBySessionOrphansAndPort() async throws {
        #expect(try await query.entries(.init(owner: AgentOwner(sessionID: "sample-session", agentPID: nil))).map(\.port) == [5173])
        // Same Claude Code process, new session ID (after /clear): still the caller's.
        #expect(try await query.entries(.init(owner: AgentOwner(sessionID: "new-session", agentPID: 40_900))).map(\.port) == [5173])
        // An ended launcher's PID never confers ownership.
        #expect(try await query.entries(.init(owner: AgentOwner(sessionID: nil, agentPID: 39_000))).isEmpty)
        #expect(try await query.entries(.init(orphansOnly: true)).map(\.port) == [3000])
        #expect(try await query.entries(.init(port: 8000)).map(\.port) == [8000])
    }

    @Test func reportsCarryProvenanceAndProbe() async throws {
        let reports = try await query.reports(.init(port: 3000), now: SampleServers.referenceDate)
        let next = try #require(reports.first)
        #expect(next.url == "http://localhost:3000/")
        #expect(next.git?.worktree == "blog-wt")
        #expect(next.agent?.kind == "claude-code")
        #expect(next.agent?.orphaned == true)
        #expect(next.http?.title == "My Blog")
        #expect(next.uptimeSeconds == 3_900)

        let json = String(decoding: try ServerReport.encoder().encode(reports), as: UTF8.self)
        #expect(json.contains("\"orphaned\" : true"))
        #expect(!json.contains("argv"))

        // Every key is present even when unknown.
        let httpServer = try #require(try await query.reports(.init(port: 8000), now: SampleServers.referenceDate).first)
        let object = try #require(try JSONSerialization.jsonObject(with: ServerReport.encoder().encode(httpServer)) as? [String: Any])
        #expect(object.keys.sorted() == [
            "agent", "framework", "git", "hidden", "http", "pid", "port", "process",
            "project", "startedAt", "stoppable", "uptimeSeconds", "url",
        ])
        #expect(object["git"] is NSNull)
    }
}
