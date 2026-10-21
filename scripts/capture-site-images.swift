// Capture the shipped SwiftUI views with inert sample data; never draw substitutes.
import AppKit
import SwiftUI
import StillHereCore

@main
struct Capture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        let scenario = FakeServerDetector.Scenario(entries: [SampleServers.next, SampleServers.flask, SampleServers.vite], probes: SampleServers.probes)
        let stores = AppStores(.preview(scenario: scenario))
        let model = ServerListModel(detector: FakeServerDetector(scenario: scenario), sessionSource: FakeSessionSource(), settings: stores.settings, signaller: ProcessSignaller(system: InertSignalSystem()), flushSource: FixedFlushSource([
            FlushCandidate(target: SignalTarget(pid: 44001, name: "node", startTime: SampleServers.referenceDate), directory: "/Users/dev/Projects/old-preview", reason: .orphaned),
            FlushCandidate(target: SignalTarget(pid: 44002, name: "esbuild", startTime: SampleServers.referenceDate), directory: "/Users/dev/Projects/old-preview", reason: .detached)
        ]), clock: FixedNow(SampleServers.referenceDate))
        model.isPanelOpen = true
        await model.refresh(.manual)
        if let screen = Bundle.main.object(forInfoDictionaryKey: "CaptureScreen") as? String {
            NSApplication.shared.setActivationPolicy(.regular)
            if screen == "about" {
                AboutPanel.show()
                NSApp.run()
            } else {
                let content = SettingsView().environment(stores.settings).environment(stores.launchAtLogin)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Still Here Settings"
                window.contentView = host
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                withExtendedLifetime(window) { NSApp.run() }
            }
            return
        }
        func menu(_ scheme: ColorScheme) -> some View {
            MenuPanel().environment(model).environment(stores.settings)
                .environment(\.serverActions, stores.actions).environment(\.colorScheme, scheme)
        }
        try await render(menu(.light), name: "menu-bar", output: output)
        try await render(menu(.dark), name: "menu-bar-dark", output: output, dark: true)
        await model.flushFlow.request(config: .defaults)
        try await render(menu(.light), name: "flush-review", output: output)
        try await render(menu(.dark), name: "flush-review-dark", output: output, dark: true)
        await model.flushFlow.confirm(config: .defaults)
        try await render(menu(.light), name: "flush-result", output: output)
        model.flushFlow.dismiss()
        model.stopFlow.requestStop(SampleServers.vite)
        try await render(menu(.light), name: "stop-confirmation", output: output)
        model.stopFlow.dismiss(SampleServers.vite)
        model.stop()
    }

    @MainActor static func render<Content: View>(_ content: Content, name: String, output: URL, dark: Bool = false, title: String? = nil) async throws {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: title == nil ? [.borderless] : [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.title = title ?? ""
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let frame = title == nil ? host : (host.superview ?? host)
        frame.displayIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { fatalError("Native bitmap unavailable") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG render unavailable") }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name): \(rep.pixelsWide)x\(rep.pixelsHigh), native SwiftUI/AppKit")
        window.orderOut(nil)
    }
}
