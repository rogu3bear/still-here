import Foundation
import Observation
import StillHereCore

/// The menu reviews one captured plan. Execution rechecks ownership for every PID;
/// closing the menu does not lose an in-progress operation or its result.
@Observable
final class FlushFlow {
    enum Phase: Equatable {
        case idle
        case scanning
        case confirming([FlushCandidate])
        case running(Int)
        case finished(FlushReport)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let source: any FlushSource
    @ObservationIgnored private let runner: FlushRunner
    @ObservationIgnored var onFinished: (() async -> Void)?

    init(source: any FlushSource, signaller: ProcessSignaller,
         exitTimeout: Duration = .seconds(3), pollInterval: Duration = .milliseconds(250)) {
        self.source = source
        runner = FlushRunner(source: source, signaller: signaller, exitTimeout: exitTimeout, pollInterval: pollInterval)
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .running: true
        default: false
        }
    }

    func request(config: IgnoreConfiguration) async {
        guard !isBusy else { return }
        phase = .scanning
        do {
            let candidates = try await source.candidates(config: config)
            phase = .confirming(candidates)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    func confirm(config: IgnoreConfiguration) async {
        guard case .confirming(let candidates) = phase, !candidates.isEmpty else { return }
        phase = .running(candidates.count)
        phase = .finished(await runner.run(candidates, config: config))
        await onFinished?()
    }
}
