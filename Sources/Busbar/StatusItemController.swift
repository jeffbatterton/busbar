import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and its dropdown panel.
///
/// Uses NSStatusItem rather than SwiftUI's MenuBarExtra because the label needs to
/// know the menu bar's real appearance (which follows the wallpaper, not just dark
/// mode) to draw colored states like the status dot.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = DropdownPanel()
    private let host: NSHostingController<DropdownPanelContent>
    private let monitor: Monitor
    private var appearanceObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var clickOutsideMonitor: Any?

    init(monitor: Monitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        var close: () -> Void = {}
        host = NSHostingController(rootView: DropdownPanelContent(monitor: monitor) {
            close()
            openSettings()
        })
        super.init()
        close = { [weak self] in self?.closePanel() }

        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closePanel() }
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            Task { @MainActor in self?.positionPanel() }
        }

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
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

    // MARK: Panel

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        positionPanel()
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        item.button?.highlight(true)

        // Clicks in other apps or on the desktop dismiss the panel, like a menu.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }

    /// Centers the panel under the menu bar icon, keeping it on screen.
    private func positionPanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = host.preferredContentSize == .zero ? host.view.fittingSize : host.preferredContentSize
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = anchor.minY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}

/// Borderless floating panel for the dropdown, styled like macOS 26's own menu bar
/// panels (no popover arrow).
private final class DropdownPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
    }

    /// Called when Escape is pressed.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The dropdown on a tinted glass background with rounded corners.
struct DropdownPanelContent: View {
    let monitor: Monitor
    let openSettings: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        DropdownView(monitor: monitor, openSettings: openSettings)
            // macOS 26 glass is very transparent; tint it so text stays readable over
            // light content. Raise the opacity for a more solid look.
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: shape)
            .modifier(PanelGlass(shape: shape))
            .fixedSize()
    }
}

private struct PanelGlass<S: Shape>: ViewModifier {
    let shape: S

    // The glass sits on its own layer behind the content; applying it to the
    // content directly restyles the text and icons as glass and drops their colors.
    func body(content: Content) -> some View {
        content.background {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
    }
}
