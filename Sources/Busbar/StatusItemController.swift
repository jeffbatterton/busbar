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
    private let openSettings: () -> Void
    private let openWindow: (NSScreen?) -> Void

    init(monitor: Monitor, openSettings: @escaping () -> Void, openWindow: @escaping (NSScreen?) -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        self.openWindow = openWindow
        var close: () -> Void = {}
        var screen: () -> NSScreen? = { nil }
        host = NSHostingController(rootView: DropdownPanelContent(monitor: monitor, openSettings: {
            close()
            openSettings()
        }, openWindow: {
            // The screen the dropdown is on, so the window opens there.
            let target = screen()
            close()
            openWindow(target)
        }))
        super.init()
        close = { [weak self] in self?.closePanel() }
        screen = { [weak self] in self?.panel.screen }

        host.sizingOptions = .preferredContentSize
        // The panel is borderless and sized only by positionPanel(). As its content view
        // controller, or with safe areas, the hosting view and the window resize each other
        // while the content changes size, until AppKit gives up and throws (when a fault
        // appeared it crashed on launch).
        host.safeAreaRegions = []
        let container = NSView()
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        panel.contentView = container
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closePanel() }
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
            }
        }

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// A click opens the dropdown; a right click or Control-click shows the menu.
    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return togglePanel() }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        closePanel()
        let menu = NSMenu()
        menu.addItem(MenuAction("Open in a Window") { [weak self] in
            self?.openWindow(self?.item.button?.window?.screen)
        })
        menu.addItem(MenuAction("Refresh Now") { [weak self] in self?.monitor.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit Busbar", key: "q") { NSApp.terminate(nil) })
        // Attached just for this click, so a plain click still opens the dropdown.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func togglePanel() {
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

        // The window includes a transparent shadow margin around the visible panel.
        let margin = DropdownPanelContent.shadowMargin
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8 - margin), visible.maxX - size.width + margin - 8)
        let top = anchor.minY - 6 + margin
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
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
        // The glass draws its own shadow, inside the content's transparent margin.
        hasShadow = false
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
    /// Transparent space around the panel so the glass's shadow isn't clipped
    /// by the window's edges (which shows up as a hard rectangular outline).
    static let shadowMargin: CGFloat = 24

    let monitor: Monitor
    let openSettings: () -> Void
    let openWindow: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        DropdownView(monitor: monitor, openSettings: openSettings, openWindow: openWindow)
            // macOS 26 glass is very transparent; tint it so text stays readable over
            // light content. Raise the opacity for a more solid look.
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: shape)
            .modifier(PanelGlass(shape: shape))
            .padding(Self.shadowMargin)
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
