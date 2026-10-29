import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and its dropdown popover.
///
/// Uses NSStatusItem rather than SwiftUI's MenuBarExtra because the label needs to
/// know the menu bar's real appearance (which follows the wallpaper, not just dark
/// mode) to draw colored states like the status dot.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private var appearanceObservation: NSKeyValueObservation?

    init(monitor: Monitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        super.init()

        let dropdown = DropdownView(monitor: monitor) { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        }
        let host = NSHostingController(rootView: dropdown)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateLabel() }
        }
        trackMonitor()
    }

    /// Re-renders the label whenever anything it reads on the monitor changes.
    private func trackMonitor() {
        withObservationTracking {
            updateLabel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackMonitor() }
        }
    }

    private func updateLabel() {
        guard let button = item.button else { return }
        button.image = MenuBarLabel.image(for: monitor, appearance: button.effectiveAppearance)
        button.setAccessibilityLabel(monitor.snapshot.map { "Bus battery \(Int($0.stateOfCharge.rounded())) percent" }
                                     ?? "Bus battery")
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
