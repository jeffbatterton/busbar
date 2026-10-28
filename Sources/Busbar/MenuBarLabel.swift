import AppKit
import BusbarCore
import SwiftUI

/// The bus battery icon, percentage, and charge direction arrow shown in the menu bar.
///
/// Menu bar labels are rendered as monochrome templates, so to show orange/red for
/// low/critical we render the label to a non-template image ourselves.
struct MenuBarLabel: View {
    let monitor: Monitor

    var body: some View {
        Image(nsImage: Self.render(level: level, text: text, flow: monitor.snapshot?.flow, color: color))
    }

    private var level: Double {
        (monitor.snapshot?.stateOfCharge ?? 0) / 100
    }

    private var text: String {
        guard let snapshot = monitor.snapshot else { return "–" }
        return "\(Int(snapshot.stateOfCharge.rounded()))%"
    }

    /// nil means "use the system menu bar color".
    private var color: NSColor? {
        if monitor.isStale { return .secondaryLabelColor }
        return switch monitor.batteryLevel {
        case .normal: nil
        case .low: .systemOrange
        case .critical: .systemRed
        }
    }

    @MainActor
    static func render(level: Double, text: String, flow: PowerSnapshot.Flow?, color: NSColor?) -> NSImage {
        let tint = Color(nsColor: color ?? .black)
        let content = HStack(spacing: 4) {
            BusBatteryIcon(level: level, color: tint)
                .frame(height: 14)
            HStack(spacing: 1) {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                switch flow {
                case .charging: Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                case .discharging: Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                case .idle, nil: EmptyView()
                }
            }
        }
        .foregroundStyle(tint)
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        // Template images get tinted by the system to match the menu bar.
        image.isTemplate = color == nil
        return image
    }
}
