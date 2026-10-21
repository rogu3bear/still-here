import SwiftUI
import StillHereCore

/// Open, Copy URL, Reveal in Finder, Open in Terminal, Stop.
struct ServerRowActions: View {
    let entry: ServerEntry

    @Environment(ServerListModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.serverActions) private var actions
    @State private var copied = false

    var body: some View {
        let folder = entry.project?.projectRoot
        HStack(spacing: 6) {
            Button("Open", systemImage: "safari") { actions.open(model.url(for: entry)) }
                .help("Open in the default browser")
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                actions.copy(model.url(for: entry))
                copied = true
            }
            .help("Copy \(model.url(for: entry).absoluteString)")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
            Button("Finder", systemImage: "folder") { folder.map(actions.reveal) }
                .disabled(folder == nil)
                .help("Reveal the project folder in Finder")
            Button("Terminal", systemImage: "terminal") {
                folder.map { actions.openInTerminal($0, using: settings.terminal) }
            }
            .disabled(folder == nil)
            .help("Open the project folder in \(settings.terminal.name)")
            Spacer(minLength: 0)
            Button("Stop", systemImage: "stop.circle", role: .destructive) {
                model.stopFlow.requestStop(entry)
            }
            .disabled(!entry.isStoppable || model.stopFlow.phase(for: entry) != nil || model.flushFlow.isBusy)
            .labelStyle(.titleAndIcon)
            .help(entry.isStoppable
                  ? "Stop this server (SIGTERM, after confirmation)"
                  : "System, daemon and app-helper processes can't be stopped from here")
        }
        // Titles only for the utility buttons so all five fit the 400 pt panel untruncated.
        .labelStyle(.titleOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
