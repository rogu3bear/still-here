import Foundation

/// A reviewable, immutable set of individual process identities. A later scan can
/// remove a target from this plan, but never add a new one after confirmation.
public struct FlushCandidate: Sendable, Hashable, Identifiable {
    public enum Reason: String, Sendable {
        case orphaned = "Launching session has ended"
        case detached = "Detached development process"
    }

    public var target: SignalTarget
    public var directory: String
    public var reason: Reason
    public var id: SignalTarget { target }

    public init(target: SignalTarget, directory: String, reason: Reason) {
        self.target = target
        self.directory = directory
        self.reason = reason
    }
}

public struct FlushSnapshot: Sendable {
    public var processes: [Int32: ProcessDetails]
    public var table: ProcessTable
    public var sessions: [AgentSession]
    public var checkouts: [Int32: String]
    public var servers: [ServerEntry]
    /// Explicit kernel outcomes; a missing dictionary key never proves exit.
    public var launchers: [Int32: ProcessLookup]
    public var now: Date
    public var uid: UInt32
    public var ownPID: Int32
    public var managedPIDs: Set<Int32>

    public init(processes: [Int32: ProcessDetails], table: ProcessTable,
                sessions: [AgentSession], checkouts: [Int32: String],
                servers: [ServerEntry], launchers: [Int32: ProcessLookup],
                now: Date = Date(), uid: UInt32 = getuid(), ownPID: Int32 = getpid(), managedPIDs: Set<Int32> = []) {
        self.processes = processes
        self.table = table
        self.sessions = sessions
        self.checkouts = checkouts
        self.servers = servers
        self.launchers = launchers
        self.now = now
        self.uid = uid
        self.ownPID = ownPID
        self.managedPIDs = managedPIDs
    }
}

public enum FlushPlanner {
    public static func candidates(in snapshot: FlushSnapshot, config: IgnoreConfiguration) -> [FlushCandidate] {
        let activeCheckouts = Set(snapshot.sessions.flatMap { $0.checkouts.map(\.checkoutRoot) })
        let members = snapshot.sessions.reduce(into: Set<Int32>()) { $0.formUnion($1.memberPIDs) }
        let sessionHosts = Set(snapshot.sessions.flatMap {
            snapshot.table.ancestors(of: $0.pid, limit: snapshot.table.records.count).map(\.pid)
        })
        let liveSessionIDs = Set(snapshot.table.records.values.filter { $0.agentKind != nil }.compactMap {
            snapshot.processes[$0.pid]?.agentEnvironment["CLAUDE_CODE_SESSION_ID"]
        })
        let servers = Dictionary(grouping: snapshot.servers, by: \.rootPID)
        return snapshot.processes.values.compactMap { process -> FlushCandidate? in
            guard process.pid > 1, process.pid != snapshot.ownPID, process.uid == snapshot.uid,
                  !snapshot.managedPIDs.contains(process.pid),
                  let name = process.name, !name.isEmpty,
                  let start = process.startTime, !process.startTimeIsApproximate,
                  let path = process.executablePath, !path.contains(".app/"),
                  let cwd = process.cwd, cwd != "/", !process.argv.isEmpty,
                  AgentMarkers.kind(name: name, executablePath: path, argv: process.argv) == nil,
                  !IgnoreClassifier.systemPrefixes.contains(where: path.hasPrefix),
                  !config.processNames.contains(where: { IgnoreClassifier.matches(name, pattern: $0) }),
                  !(servers[process.pid] ?? []).contains(where: { $0.isHidden || !$0.isStoppable }),
                  isDevelopmentProcess(process, isServer: servers[process.pid] != nil),
                  !members.contains(process.pid),
                  !sessionHosts.contains(process.pid),
                  !(snapshot.checkouts[process.pid].map(activeCheckouts.contains) ?? false)
            else { return nil }

            let ancestors = snapshot.table.ancestors(of: process.pid)
            // A truncated, missing, reused or uninspectable parent is unknown ownership.
            var child = process
            for ancestor in ancestors {
                guard child.ppid == ancestor.pid, ancestor.startTime <= (child.startTime ?? .distantPast),
                      ancestor.agentKind == nil, ancestor.appBundle == nil,
                      !snapshot.managedPIDs.contains(ancestor.pid),
                      !(servers[ancestor.pid] ?? []).contains(where: { $0.isHidden || !$0.isStoppable }),
                      let details = snapshot.processes[ancestor.pid] else { return nil }
                child = details
            }
            guard child.ppid == 1 else { return nil }

            let lineage = [process] + ancestors.compactMap { snapshot.processes[$0.pid] }
            var orphaned = false
            for member in lineage {
                let environment = member.agentEnvironment
                if let session = environment["CLAUDE_CODE_SESSION_ID"], liveSessionIDs.contains(session) { return nil }
                guard let agent = AgentDetector.fromEnvironment(environment) else {
                    guard environment.isEmpty else { return nil }
                    continue
                }
                guard let pid = agent.launcherPID, let observation = snapshot.launchers[pid] else { return nil }
                switch observation {
                case .notFound: orphaned = true
                case .found(let launcher) where launcher.startTime > start: orphaned = true
                case .found, .denied, .failed: return nil
                }
            }
            // Unattributed processes need both a checkout and a settled detached lifetime.
            guard orphaned || (snapshot.checkouts[process.pid] != nil && snapshot.now.timeIntervalSince(start) >= 60)
            else { return nil }
            return FlushCandidate(target: SignalTarget(pid: process.pid, name: name, startTime: start),
                                  directory: cwd, reason: orphaned ? .orphaned : .detached)
        }.sorted {
            // Workers first, then their parents. Every signal still addresses one PID.
            let leftDepth = snapshot.table.ancestors(of: $0.target.pid).count
            let rightDepth = snapshot.table.ancestors(of: $1.target.pid).count
            return leftDepth == rightDepth ? $0.target.pid < $1.target.pid : leftDepth > rightDepth
        }
    }

    private static func isDevelopmentProcess(_ process: ProcessDetails, isServer: Bool) -> Bool {
        let name = (process.executablePath.map { ($0 as NSString).lastPathComponent } ?? process.name ?? "").lowercased()
        if ["node", "bun", "deno", "esbuild", "workerd"].contains(name) { return true }
        let guess = FrameworkDetector.guess(FrameworkSignals(argv: process.argv, name: process.name ?? name,
                                                           executablePath: process.executablePath, cwd: process.cwd))
        if guess.source == .argv, guess.name != "Jupyter" { return true }
        return isServer && (process.executablePath?.contains("/target/debug/") == true
                            || process.executablePath?.contains("/target/release/") == true)
    }
}
