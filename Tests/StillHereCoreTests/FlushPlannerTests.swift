import Darwin
import Foundation
import Testing
@testable import StillHereCore

@Suite struct FlushPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = "/projects/demo"

    func process(_ pid: Int32 = 100, parent: Int32 = 1, name: String = "node",
                 environment: [String: String] = [:]) -> ProcessDetails {
        ProcessDetails(pid: pid, ppid: parent, uid: 501, name: name,
                       startTime: now.addingTimeInterval(-120), executablePath: "/opt/homebrew/bin/\(name)",
                       argv: [name, "worker.js"], cwd: directory, agentEnvironment: environment)
    }

    func snapshot(_ processes: [ProcessDetails], sessions: [AgentSession] = [],
                  launchers: [Int32: ProcessLookup] = [:], servers: [ServerEntry] = []) -> FlushSnapshot {
        FlushSnapshot(processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }),
                      table: ProcessTable(processes.map {
                          ProcessRecord(pid: $0.pid, ppid: $0.ppid ?? 0, name: $0.name ?? "",
                                        startTime: $0.startTime ?? now,
                                        agentKind: AgentMarkers.kind(name: $0.name, executablePath: $0.executablePath, argv: $0.argv),
                                        appBundle: $0.executablePath.flatMap(ProcessRecord.appBundle(containing:)))
                      }), sessions: sessions,
                      checkouts: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, directory) }),
                      servers: servers, launchers: launchers, now: now, uid: 501, ownPID: 999)
    }

    func plan(_ snapshot: FlushSnapshot) -> [FlushCandidate] {
        FlushPlanner.candidates(in: snapshot, config: .defaults)
    }

    @Test func detachedNodeAndNonListeningWorkerAreIncludedOnceWorkersFirst() {
        let targets = plan(snapshot([process(), process(101, parent: 100)]))
        #expect(targets.map(\.target.pid) == [101, 100])
        #expect(targets.allSatisfy { $0.reason == .detached })
    }

    @Test func confirmedMissingLauncherMakesAnOrphan() {
        let entry = process(environment: ["CLAUDECODE": "1", "CLAUDE_PID": "40"])
        #expect(plan(snapshot([entry], launchers: [40: .notFound])).first?.reason == .orphaned)
    }

    @Test func launcherLookupMustEstablishExit() {
        let entry = process(environment: ["CLAUDECODE": "1", "CLAUDE_PID": "40"])
        let live = LiveProcess(startTime: now.addingTimeInterval(-300), name: "claude", uid: 501)
        for lookups: [Int32: ProcessLookup] in [[:], [40: .denied], [40: .failed(errno: EIO)], [40: .found(live)]] {
            #expect(plan(snapshot([entry], launchers: lookups)).isEmpty)
        }
        let reused = LiveProcess(startTime: now, name: "other", uid: 501)
        #expect(plan(snapshot([entry], launchers: [40: .found(reused)])).count == 1)
    }

    @Test func activeAncestryWinsOverStaleOrphanMarker() {
        let agent = process(40, name: "codex")
        let child = process(parent: 40, environment: ["CLAUDECODE": "1", "CLAUDE_PID": "50"])
        #expect(plan(snapshot([agent, child], launchers: [50: .notFound])).isEmpty)
    }

    @Test func aDevelopmentHostOfAnActiveAgentInAnotherCheckoutIsPreserved() {
        let host = process()
        var agent = process(40, parent: 100, name: "codex")
        agent.cwd = "/projects/other"
        let session = AgentSession(pid: 40, kind: .codex, startTime: now,
                                   checkouts: [GitContext(checkoutRoot: "/projects/other")])
        var source = snapshot([host, agent], sessions: [session])
        source.checkouts[40] = "/projects/other"
        #expect(plan(source).isEmpty)
    }

    @Test func newbornIdleAndReviewerSessionsProtectMembersAndDetachedCheckoutProcesses() {
        let detached = process(environment: ["CLAUDECODE": "1", "CLAUDE_PID": "50"])
        for role: SessionRole in [.writer, .reviewer(reason: "review")] {
            let checkout = GitContext(checkoutRoot: directory)
            let session = AgentSession(pid: 40, kind: .codex, startTime: now, checkouts: [checkout], role: role)
            #expect(plan(snapshot([detached], sessions: [session], launchers: [50: .notFound])).isEmpty)
            let idle = AgentSession(pid: 40, kind: .codex, startTime: now, memberPIDs: [100], role: role)
            #expect(plan(snapshot([detached], sessions: [idle], launchers: [50: .notFound])).isEmpty)
        }
    }

    @Test func unknownMarkersAndInheritedUnknownOwnershipArePreserved() {
        for environment in [["CODEX_SANDBOX": "1"], ["AI_AGENT": "codex"], ["CLAUDECODE": "1"],
                            ["CLAUDE_PID": "50"], ["CLAUDE_CODE_SESSION_ID": "unknown"]] {
            #expect(plan(snapshot([process(environment: environment)])).isEmpty)
            #expect(plan(snapshot([process(environment: environment), process(101, parent: 100)])).isEmpty)
        }
    }

    @Test func activeSessionIDProtectsDetachedProcessWithDeadLauncherPID() {
        let agent = process(40, name: "claude", environment: ["CLAUDE_CODE_SESSION_ID": "resumed"])
        let detached = process(environment: ["CLAUDECODE": "1", "CLAUDE_PID": "50", "CLAUDE_CODE_SESSION_ID": "resumed"])
        #expect(plan(snapshot([agent, detached], launchers: [50: .notFound])).isEmpty)
    }

    @Test func missingCyclicAndReusedParentsArePreserved() {
        #expect(plan(snapshot([process(parent: 50)])).isEmpty)
        #expect(plan(snapshot([process(parent: 101), process(101, parent: 100)])).isEmpty)
        var parent = process(50)
        parent.startTime = now
        #expect(plan(snapshot([parent, process(parent: 50)])).map(\.target.pid) != [100])
        #expect(!plan(snapshot([parent, process(parent: 50)])).contains { $0.target.pid == 100 })
    }

    @Test func terminalAndApplicationHelpersArePreserved() {
        var terminal = process(40, name: "Terminal")
        terminal.executablePath = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        #expect(plan(snapshot([terminal, process(parent: 40)])).isEmpty)
        var helper = process()
        helper.executablePath = "/Applications/Editor.app/Contents/Resources/node"
        #expect(plan(snapshot([helper])).isEmpty)
    }

    @Test func managedServicesAndTheirWorkersArePreserved() {
        var source = snapshot([process(), process(101, parent: 100)])
        source.managedPIDs = [100]
        #expect(plan(source).isEmpty)
    }

    @Test func launchdListRequiresACompleteRecognizedReply() {
        #expect(LiveFlushSource.managedPIDs(from: "PID\tStatus\tLabel\n100\t0\tdev.service\n-\t-9\tstopped.service\n") == [100])
        #expect(LiveFlushSource.managedPIDs(from: "") == nil)
        #expect(LiveFlushSource.managedPIDs(from: "PID\tStatus\tLabel\nunknown\t0\tdev.service") == nil)
        #expect(LiveFlushSource.managedPIDs(from: "PID\tStatus\tLabel\n100\tunknown\tdev.service") == nil)
    }

    @Test func unverifiedNewProtectedAndOtherUserProcessesArePreserved() {
        var variants = [ProcessDetails]()
        var entry = process(); entry.startTime = nil; variants.append(entry)
        entry = process(); entry.startTimeIsApproximate = true; variants.append(entry)
        entry = process(); entry.uid = 502; variants.append(entry)
        entry = process(); entry.argv = []; variants.append(entry)
        entry = process(); entry.cwd = "/"; variants.append(entry)
        entry = process(); entry.executablePath = nil; variants.append(entry)
        entry = process(); entry.startTime = now; variants.append(entry)
        variants.append(process(999))
        for variant in variants { #expect(plan(snapshot([variant])).isEmpty) }
    }

    @Test func genericPythonJobsArePreservedButDevServersAreIncluded() {
        var python = process(name: "python3")
        python.argv = ["python3", "train.py"]
        #expect(plan(snapshot([python])).isEmpty)
        python.argv = ["python3", "-m", "http.server", "8000"]
        #expect(plan(snapshot([python])).count == 1)
    }

    @Test func hiddenServersAndProcessesOutsideACheckoutArePreserved() {
        let entry = process()
        var source = snapshot([entry])
        source.checkouts = [:]
        #expect(plan(source).isEmpty)
        let server = ServerEntry(port: 3000, rootPID: 100, bindings: [], command: "node",
                                 process: entry, framework: FrameworkGuess(name: "Node", source: .runtime),
                                 hiddenReason: .ignoredName("node"))
        #expect(plan(snapshot([entry], servers: [server])).isEmpty)
    }
}
