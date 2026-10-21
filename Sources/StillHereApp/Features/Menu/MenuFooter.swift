import AppKit
import SwiftUI

/// Settings, About and Quit.
struct MenuFooter: View {
    @Environment(ServerListModel.self) private var model
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 12) {
            OpenSettingsButton()
            Spacer()
            Button("Flush", systemImage: "wind") {
                Task { await model.flushFlow.request(config: settings.ignoreConfiguration) }
            }
            .disabled(model.flushFlow.isBusy || model.stopFlow.isBusy)
            .help("Review orphaned servers and detached dev processes to stop. Active sessions are preserved.")
            Button("About Still Here") { AboutPanel.show() }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .help("Quit Still Here (⌘Q)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
