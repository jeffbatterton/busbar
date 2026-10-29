import AppKit
import BusbarCore
import SwiftUI

/// Renders the menu bar label: bus battery icon, percentage, charge direction arrow,
/// and a status dot when something needs attention.
///
/// With nothing to flag, the label is a template image so macOS tints it to match
/// the menu bar exactly. Colored states (low/critical, dot, stale) can't be templates,
/// so their colors are resolved against the menu bar's actual appearance.
enum MenuBarLabel {
    @MainActor
    static func image(for monitor: Monitor, appearance: NSAppearance) -> NSImage {
        let snapshot = monitor.snapshot
        let tint: NSColor? = monitor.isStale ? .secondaryLabelColor : nil
        // Like the system battery: only the charge fill takes the level color.
        let fill: NSColor? = if monitor.isStale {
            nil
        } else {
            switch monitor.batteryLevel {
            case .normal: nil
            case .low: .systemYellow
            case .critical: .systemRed
            }
        }
        // Low/critical battery is already shown by the label color, so the dot is
        // reserved for problems: unavailable battery, faults, offline, API errors.
        let dot: NSColor? = monitor.hasProblem ? .systemRed : nil
        return render(level: (snapshot?.stateOfCharge ?? 0) / 100,
                      text: snapshot.map { "\(Int($0.stateOfCharge.rounded()))%" } ?? "–",
                      flow: snapshot?.flow, tint: tint, fill: fill, dot: dot, appearance: appearance)
    }

    @MainActor
    static func render(level: Double, text: String, flow: PowerSnapshot.Flow?,
                       tint: NSColor?, fill: NSColor?, dot: NSColor?, appearance: NSAppearance) -> NSImage {
        let isTemplate = tint == nil && fill == nil && dot == nil
        let foreground = isTemplate ? Color.black : resolve(tint ?? .labelColor, in: appearance)
        let fillColor = fill.map { resolve($0, in: appearance) }
        let dotColor = dot.map { resolve($0, in: appearance) }

        let content = HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                BusBatteryIcon(level: level, color: foreground, fillColor: fillColor)
                if let dotColor {
                    // Cut a ring out of the icon so the dot reads even on a same-colored label.
                    Circle().frame(width: 9, height: 9).offset(x: 2.5, y: -2.5).blendMode(.destinationOut)
                    Circle().fill(dotColor).frame(width: 6, height: 6).offset(x: 1, y: -1)
                }
            }
            .compositingGroup()
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
        .foregroundStyle(foreground)
        // Room for the dot, which overhangs the top of the icon.
        .padding(.top, 2)
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = isTemplate
        return image
    }

    /// Resolves a dynamic system color (e.g. labelColor) for a specific appearance.
    private static func resolve(_ color: NSColor, in appearance: NSAppearance) -> Color {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: resolved)
    }
}
