import Foundation

public struct FlushResult: Sendable, Hashable, Identifiable {
    public var candidate: FlushCandidate
    /// nil means the target was preserved by a fresh ownership/identity check.
    public var result: ServerStopper.Result?
    public var id: SignalTarget { candidate.id }
}

public struct FlushReport: Sendable, Hashable {
    public var results: [FlushResult] = []
    public var error: String?
    public init() {}
    public var stopped: Int { results.count { $0.result?.succeeded == true } }
    public var preserved: Int { results.count { $0.result == nil } }
    public var unresolved: Int { results.count { $0.result != nil && $0.result?.succeeded != true } }
}

public struct FlushRunner: Sendable {
    private let source: any FlushSource
    private let stopper: ServerStopper

    public init(source: any FlushSource, signaller: ProcessSignaller,
                exitTimeout: Duration = .seconds(3), pollInterval: Duration = .milliseconds(250)) {
        self.source = source
        stopper = ServerStopper(signaller: signaller, exitTimeout: exitTimeout, pollInterval: pollInterval)
    }

    public func run(_ confirmed: [FlushCandidate], config: IgnoreConfiguration) async -> FlushReport {
        var report = FlushReport()
        var seen: Set<SignalTarget> = []
        for candidate in confirmed where seen.insert(candidate.target).inserted {
            guard !Task.isCancelled else { report.error = "Flush cancelled."; break }
            do {
                let current = try await source.candidates(config: config)
                guard !Task.isCancelled else { report.error = "Flush cancelled."; break }
                guard current.contains(where: { $0.target == candidate.target }) else {
                    report.results.append(FlushResult(candidate: candidate, result: nil))
                    continue
                }
                let result = await stopper.terminate(candidate.target)
                report.results.append(FlushResult(candidate: candidate, result: result))
            } catch {
                report.error = error.localizedDescription
                break
            }
        }
        return report
    }
}
