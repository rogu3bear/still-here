import Foundation
import ServiceManagement
import StillHereCore

/// The composition root: every dependency the app's stores and views need.
struct AppEnvironment {
    var detector: any ServerDetector
    var sessionSource: any SessionSource
    var defaults: UserDefaults
    var signaller: ProcessSignaller
    var loginItems: any LoginItemService
    var actions: any ServerActions
    var flushSource: any FlushSource = FixedFlushSource()

    /// Real lsof + libproc detection, real signals, real login items.
    static func live() -> AppEnvironment {
        AppEnvironment(
            detector: DefaultServerDetector(),
            sessionSource: LiveSessionSource(),
            defaults: ProductPreferences.applicationDefaults(),
            signaller: ProcessSignaller(system: DarwinSignalSystem()),
            loginItems: MainAppLoginItem(),
            actions: LiveServerActions(),
            flushSource: LiveFlushSource()
        )
    }

    /// Canned servers; signals, login items and actions are inert.
    static func preview(scenario: FakeServerDetector.Scenario = .init()) -> AppEnvironment {
        AppEnvironment(
            detector: FakeServerDetector(scenario: scenario),
            sessionSource: FakeSessionSource(),
            defaults: UserDefaults(suiteName: "com.mlnavigator.stillhere.preview") ?? .standard,
            signaller: ProcessSignaller(system: InertSignalSystem()),
            loginItems: InertLoginItem(),
            actions: InertServerActions()
        )
    }
}

/// The stores built from an environment. Created once per app (or preview).
struct AppStores {
    let settings: SettingsStore
    let model: ServerListModel
    let launchAtLogin: LaunchAtLoginController
    let actions: any ServerActions

    init(_ environment: AppEnvironment) {
        settings = SettingsStore(defaults: environment.defaults)
        model = ServerListModel(
            detector: environment.detector,
            sessionSource: environment.sessionSource,
            settings: settings,
            signaller: environment.signaller,
            flushSource: environment.flushSource
        )
        launchAtLogin = LaunchAtLoginController(service: environment.loginItems)
        actions = environment.actions
    }
}

/// Signals nothing: every PID is reported as gone.
nonisolated struct InertSignalSystem: SignalSystem {
    func send(_ signal: Int32, to pid: Int32) -> Int32 { ESRCH }
    func isAlive(_ pid: Int32) -> Bool { false }
    func lookup(_ pid: Int32) -> ProcessLookup { .notFound }
}

struct InertLoginItem: LoginItemService {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
