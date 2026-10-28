import SwiftUI

@main
struct BusbarApp: App {
    @State private var settings: AppSettings
    @State private var monitor: Monitor

    init() {
        let settings = AppSettings()
        let monitor = Monitor(settings: settings)
        monitor.start()
        _settings = State(initialValue: settings)
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Busbar Settings", id: "settings") {
            SettingsView(settings: settings, monitor: monitor)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
