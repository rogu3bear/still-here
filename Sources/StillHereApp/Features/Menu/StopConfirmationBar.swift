import SwiftUI
import StillHereCore

/// Inline stop flow. Inline (rather than an alert) because alerts attached to a
/// menu bar panel can close the panel when they take focus.
struct StopConfirmationBar: View {
    let entry: ServerEntry
    let phase: StopFlow.Phase

    @Environment(ServerListModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.caption)
        .controlSize(.small)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 6))
        .disabled(model.flushFlow.isBusy)
    }

    @ViewBuilder
    private var content: some View {
        let flow = model.stopFlow
        let port = entry.port
        switch phase {
        case .confirmTerminate(let target):
            Text("Stop \(target.name) (PID \(target.pid)) on :\(port)?")
            Spacer(minLength: 4)
            Button("Cancel") { flow.dismiss(entry) }
                .keyboardShortcut(.cancelAction)
            Button("Stop", role: .destructive) { Task { await flow.confirmTerminate(entry) } }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        case .terminating(let target):
            ProgressView().controlSize(.mini)
            Text("Sent SIGTERM to PID \(target.pid); waiting for it to exit…")
        case .stillRunning(let target):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("PID \(target.pid) (\(target.name)) is still running after SIGTERM.")
            Spacer(minLength: 4)
            Button("Cancel") { flow.dismiss(entry) }
                .keyboardShortcut(.cancelAction)
            Button("Force Kill", role: .destructive) { Task { await flow.confirmForceKill(entry) } }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Send SIGKILL to PID \(target.pid)")
        case .killing(let target):
            ProgressView().controlSize(.mini)
            Text("Sent SIGKILL to PID \(target.pid)…")
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Dismiss") { flow.dismiss(entry) }
        }
    }
}
