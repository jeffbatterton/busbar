import AppKit
import SwiftUI

/// Busbar in a window of its own: the chart fills it, with everything else from the dropdown
/// in a sidebar down the left. It resizes and goes full screen like any window. While it's
/// open Busbar is a regular app with a Dock icon; closing it goes back to the menu bar.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private let monitor: Monitor
    private let openSettings: () -> Void
    private var window: NSWindow?

    init(monitor: Monitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
    }

    /// Opens the window on `screen`, or brings it forward if it's already open.
    func show(on screen: NSScreen?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: WindowContent(monitor: monitor, openSettings: openSettings))
        // The window sizes the view, not the other way round.
        host.sizingOptions = []
        let window = BusbarWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Busbar"
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1180, height: 760))
        // Reopens at the size and place it was last closed at; the first time, centered on the
        // screen the dropdown was on.
        if !window.setFrameUsingName("Busbar"), let visible = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        window.setFrameAutosaveName("Busbar")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Closes on ⌘W, which a menu bar app has no File menu for.
private final class BusbarWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct WindowContent: View {
    let monitor: Monitor
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            DropdownView(monitor: monitor, openSettings: openSettings, layout: .sidebar)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.quinary)
            Divider()
            Group {
                if monitor.settings.historyClient != nil {
                    BatteryHistory(monitor: monitor, isLarge: true)
                } else {
                    Text("Set up Battery history in Settings to see the chart here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 760, minHeight: 600)
        .ignoresSafeArea()
    }
}
