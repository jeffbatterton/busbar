import AppKit
import SwiftUI

@main
struct BusbarApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // The menu bar item and settings window are AppKit-managed (see AppDelegate);
        // SwiftUI requires at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var monitor = Monitor(settings: settings)
    private var statusItem: StatusItemController?
    private lazy var window = WindowController(monitor: monitor) { [weak self] in self?.showSettings() }
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(monitor: monitor, openSettings: { [weak self] in self?.showSettings() },
                                          openWindow: { [weak self] in self?.window.show(on: $0) })
        monitor.start()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, monitor: monitor)))
            window.title = "Busbar Settings"
            // Full-size content lets the sidebar run up under the title bar, as in System Settings.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
