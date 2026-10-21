import SwiftUI

/// Root of the window-style menu panel. SwiftUI mounts it when the panel opens and
/// unmounts it when it closes, so `.task` is the refresh-on-open hook (and is cancelled,
/// with any probes it started, on close).
struct MenuPanel: View {
    @Environment(ServerListModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader()
            Divider()
            FlushPanel()
            SessionsSection()
            ServerList()
            Divider()
            MenuFooter()
        }
        .frame(width: 400)
        .task {
            model.isPanelOpen = true
            await model.refresh(.menuOpened)
        }
        .onDisappear { model.isPanelOpen = false }
    }
}
