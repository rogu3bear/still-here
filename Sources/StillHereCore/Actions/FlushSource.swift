import Foundation

public protocol FlushSource: Sendable {
    func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate]
}

public enum FlushScanError: Error, LocalizedError {
    case ownershipUnavailable

    public var errorDescription: String? {
        "Process ownership could not be fully inspected. Nothing else was stopped."
    }
}

/// On-demand scans include processes with no listening port and all agent sessions,
/// including newborn and idle sessions omitted from the menu's collision display.
public struct LiveFlushSource: FlushSource {
    private let detector: any ServerDetector

    public init(detector: any ServerDetector = DefaultServerDetector()) { self.detector = detector }

    @concurrent
    public func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] {
        // Finish asynchronous listener work before capturing the ownership graph.
        let servers = try await detector.scan(config: config)
        let jobs = try await Subprocess().run("/bin/launchctl", ["list"])
        guard jobs.status == 0, let managedPIDs = Self.managedPIDs(from: jobs.text) else {
            throw FlushScanError.ownershipUnavailable
        }
        guard let pids = Libproc.pids(for: getuid()), !pids.isEmpty else { throw FlushScanError.ownershipUnavailable }
        var processes: [Int32: ProcessDetails] = [:]
        var records: [ProcessRecord] = []
        for pid in pids {
            switch Libproc.bsdInfo(pid) {
            case .notFound: continue
            case .denied, .failed: throw FlushScanError.ownershipUnavailable
            case .found(let info):
                guard info.uid == getuid() else { continue }
                let args = Libproc.procArgs(pid).flatMap(ProcArgsParser.parse)
                let path = Libproc.executablePath(pid)
                // Node-hosted agents cannot be identified from their name alone.
                if info.name == "node", args == nil { throw FlushScanError.ownershipUnavailable }
                let argv = args?.argv ?? []
                let kind = AgentMarkers.kind(name: info.name, executablePath: path, argv: argv)
                records.append(ProcessRecord(pid: pid, ppid: info.ppid, name: info.name, startTime: info.startTime,
                                             agentKind: kind, appBundle: path.flatMap(ProcessRecord.appBundle(containing:)),
                                             isAppServer: kind != nil && ProcessRecord.isAppServer(argv: argv)))
                processes[pid] = ProcessDetails(pid: pid, ppid: info.ppid, uid: info.uid, name: info.name,
                                               startTime: info.startTime, executablePath: path, argv: argv,
                                               cwd: Libproc.currentDirectory(pid), agentEnvironment: args?.agentEnvironment ?? [:])
            }
        }
        let table = ProcessTable(records)
        let home = NSHomeDirectory()
        var contexts: [String: GitContext] = [:]
        for directory in Set(processes.values.compactMap(\.cwd)) where directory != "/" && directory != home {
            if let context = GitReader.context(for: directory, home: home), context.checkoutRoot != home {
                contexts[directory] = context
            }
        }
        let sessions = SessionScanner.sessions(in: table, cwd: { processes[$0]?.cwd },
                                              checkout: { contexts[$0] }, home: home, now: Date())
        let launchers = Set(processes.values.compactMap { AgentDetector.fromEnvironment($0.agentEnvironment)?.launcherPID })
        let system = DarwinSignalSystem()
        let snapshot = FlushSnapshot(processes: processes, table: table, sessions: sessions,
                                     checkouts: processes.compactMapValues { $0.cwd.flatMap { contexts[$0]?.checkoutRoot } },
                                     servers: servers,
                                     launchers: Dictionary(uniqueKeysWithValues: launchers.map { ($0, system.lookup($0)) }),
                                     managedPIDs: managedPIDs)
        return FlushPlanner.candidates(in: snapshot, config: config)
    }

    static func managedPIDs(from output: String) -> Set<Int32>? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.first?.split(whereSeparator: \.isWhitespace).map(String.init) == ["PID", "Status", "Label"] else { return nil }
        var result: Set<Int32> = []
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, Int32(fields[1]) != nil else { return nil }
            if fields[0] == "-" { continue }
            guard let pid = Int32(fields[0]), pid > 1 else { return nil }
            result.insert(pid)
        }
        return result
    }
}

/// Inert source for previews and tests; never enumerates the host's processes.
public struct FixedFlushSource: FlushSource {
    public var entries: [FlushCandidate]
    public init(_ entries: [FlushCandidate] = []) { self.entries = entries }
    public func candidates(config: IgnoreConfiguration) async throws -> [FlushCandidate] { entries }
}
