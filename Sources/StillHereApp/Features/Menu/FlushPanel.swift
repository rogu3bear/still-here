import SwiftUI
import StillHereCore

/// Inline review keeps the menu open while the user confirms the captured targets.
struct FlushPanel: View {
    @Environment(ServerListModel.self) private var model
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if model.flushFlow.phase != .idle {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .font(.caption)
            .controlSize(.small)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            Divider()
        }
    }

    @ViewBuilder private var content: some View {
        let flow = model.flushFlow
        switch flow.phase {
        case .idle:
            EmptyView()
        case .scanning:
            HStack { ProgressView().controlSize(.small); Text("Checking processes and active sessions…") }
        case .confirming(let candidates):
            Text(candidates.isEmpty ? "Nothing to flush" : "Flush \(candidates.count) leftover processes?")
                .font(.callout.weight(.semibold))
            Text("Processes tied to active sessions and uncertain ownership are left running.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !candidates.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { candidate in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.target.name) · PID \(candidate.target.pid)")
                                Text("\((candidate.directory as NSString).lastPathComponent) · \(candidate.reason.rawValue)")
                                    .foregroundStyle(.secondary)
                            }
                            .help(candidate.directory)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(candidates.count) * 36, 130))
            }
            HStack {
                Button(candidates.isEmpty ? "Done" : "Cancel") { flow.dismiss() }
                Spacer()
                if !candidates.isEmpty {
                    Button("Stop \(candidates.count) processes", role: .destructive) {
                        Task { await flow.confirm(config: settings.ignoreConfiguration) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .running(let count):
            HStack { ProgressView().controlSize(.small); Text("Flushing \(count) processes…") }
        case .finished(let report):
            Text("Flush: \(report.stopped) stopped, \(report.preserved) preserved, \(report.unresolved) unresolved")
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if let error = report.error { Text(error).foregroundStyle(.red) }
            let unresolved = report.results.filter { $0.result != nil && $0.result?.succeeded != true }
            if !unresolved.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(unresolved) { item in
                            Text("\(item.candidate.target.name) (\(item.candidate.target.pid)): \(item.result?.message ?? "")")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(height: min(CGFloat(unresolved.count) * 44, 100))
            }
            Button("Done") { flow.dismiss() }
        case .failed(let error):
            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Done") { flow.dismiss() }
        }
    }
}
