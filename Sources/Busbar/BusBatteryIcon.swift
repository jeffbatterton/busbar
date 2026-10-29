import SwiftUI

/// The bus logo drawn in the style of the system battery icon: an outlined body,
/// the roof box as the terminal, solid wheels, and a fill bar for the charge level.
///
/// Geometry is in logo pixels, measured from the 800px logo and then optically
/// adjusted for menu bar size (taller roof, bigger wheels, rounder corners).
struct BusBatteryIcon: View {
    /// 0–1
    var level: Double
    var color: Color
    /// Color of the charge fill; defaults to `color`.
    var fillColor: Color? = nil

    static let aspectRatio = Geometry.bounds.width / Geometry.bounds.height

    var body: some View {
        Canvas { context, size in
            let g = Geometry.self
            let scale = size.height / g.bounds.height
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -g.bounds.minX, y: -g.bounds.minY)
            let shading = GraphicsContext.Shading.color(color)

            // Roof: rounded on top, square where it overlaps the body outline.
            var roof = Path()
            roof.addRoundedRect(in: CGRect(x: g.roofX, y: g.bodyTop - g.roofHeight,
                                           width: g.roofWidth, height: g.roofHeight + g.stroke),
                                cornerRadii: RectangleCornerRadii(topLeading: g.roofRadius, topTrailing: g.roofRadius))
            context.fill(roof, with: shading)

            // Wheels: half discs hanging below the body.
            for cx in g.wheelCenters {
                var wheel = Path()
                wheel.move(to: CGPoint(x: cx - g.wheelRadius, y: g.bodyBottom - g.stroke))
                wheel.addLine(to: CGPoint(x: cx - g.wheelRadius, y: g.bodyBottom))
                wheel.addRelativeArc(center: CGPoint(x: cx, y: g.bodyBottom), radius: g.wheelRadius,
                                     startAngle: .degrees(180), delta: .degrees(-180))
                wheel.addLine(to: CGPoint(x: cx + g.wheelRadius, y: g.bodyBottom - g.stroke))
                wheel.closeSubpath()
                context.fill(wheel, with: shading)
            }

            // Body outline, stroked inside its bounds.
            let half = g.stroke / 2
            let outline = Path(roundedRect: CGRect(x: g.bodyX + half, y: g.bodyTop + half,
                                                   width: g.bodyWidth - g.stroke,
                                                   height: g.bodyBottom - g.bodyTop - g.stroke),
                               cornerRadius: g.bodyRadius - half)
            context.stroke(outline, with: shading, lineWidth: g.stroke)

            // Charge fill, inset by stroke + gap, growing left to right.
            let clamped = min(1, max(0, level))
            guard clamped > 0 else { return }
            let inset = g.stroke + g.gap
            let inner = CGRect(x: g.bodyX + inset, y: g.bodyTop + inset,
                               width: g.bodyWidth - inset * 2, height: g.bodyBottom - g.bodyTop - inset * 2)
            let radius = max(6, g.bodyRadius - inset * 0.6)
            let fill = CGRect(x: inner.minX, y: inner.minY,
                              width: max(radius * 2, inner.width * clamped), height: inner.height)
            context.fill(Path(roundedRect: fill, cornerRadius: radius), with: .color(fillColor ?? color))
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
    }

    private enum Geometry {
        static let bodyX: CGFloat = 98
        static let bodyWidth: CGFloat = 604
        static let bodyTop: CGFloat = 274
        static let bodyBottom: CGFloat = 525
        static let bodyRadius: CGFloat = 48
        static let stroke: CGFloat = 36
        static let gap: CGFloat = 26

        static let roofX: CGFloat = 215
        static let roofWidth: CGFloat = 257
        static let roofHeight: CGFloat = 62
        static let roofRadius: CGFloat = 14

        static let wheelCenters: [CGFloat] = [223, 576]
        static let wheelRadius: CGFloat = 54

        static let bounds = CGRect(x: bodyX, y: bodyTop - roofHeight,
                                   width: bodyWidth, height: bodyBottom + wheelRadius - (bodyTop - roofHeight))
    }
}
