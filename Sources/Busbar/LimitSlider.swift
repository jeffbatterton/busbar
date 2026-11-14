import BusbarCore
import SwiftUI

/// A 0–100% track with a thumb for each charge limit: the discharge limit on the left and
/// the charge limit on the right, with the charge in use lit between them. Each thumb only
/// moves within what the Delta Pro accepts, and the new limit is sent when it's let go.
struct LimitSlider: View {
    let dischargeLimit: Double
    let chargeLimit: Double
    var isEnabled = true
    let onChange: (ChargeLimit, Int) -> Void

    /// Where a thumb is while it's dragged, before it's sent.
    @State private var dragging: (limit: ChargeLimit, percent: Double)?

    private static let thumb: CGFloat = 20
    private static let trackHeight: CGFloat = 6

    private func percent(_ limit: ChargeLimit) -> Double {
        if let dragging, dragging.limit == limit { return dragging.percent }
        return limit == .discharge ? dischargeLimit : chargeLimit
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                caption("Discharge to", percent(.discharge), alignment: .leading)
                Spacer()
                caption("Charge to", percent(.charge), alignment: .trailing)
            }
            GeometryReader { geometry in
                let width = geometry.size.width - Self.thumb
                let x = { (percent: Double) in Self.thumb / 2 + width * percent / 100 }
                let low = x(percent(.discharge)), high = x(percent(.charge))
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                        .frame(height: Self.trackHeight)
                        .padding(.horizontal, Self.thumb / 2)
                    // Where each thumb can go, faintly, so the gap between reads as off-limits.
                    ForEach([ChargeLimit.discharge, .charge], id: \.self) { limit in
                        Capsule().fill(.primary.opacity(0.08))
                            .frame(width: x(limit.range.upperBound) - x(limit.range.lowerBound) + Self.trackHeight,
                                   height: Self.trackHeight + 6)
                            .offset(x: x(limit.range.lowerBound) - Self.trackHeight / 2)
                    }
                    Capsule().fill(.green)
                        .frame(width: max(0, high - low), height: Self.trackHeight)
                        .offset(x: low)
                        .glow(.green, intensity: 0.4)
                    thumb(.discharge, at: low, width: width)
                    thumb(.charge, at: high, width: width)
                }
                .frame(height: geometry.size.height)
                .coordinateSpace(.named(Self.space))
            }
            .frame(height: Self.thumb + 4)
            HStack {
                ForEach([0, 25, 50, 75, 100], id: \.self) { mark in
                    if mark > 0 { Spacer() }
                    Text("\(mark)%")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }

    private func caption(_ title: String, _ percent: Double, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(percent))%").font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private func thumb(_ limit: ChargeLimit, at x: CGFloat, width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .overlay(Circle().strokeBorder(.black.opacity(0.08)))
            .frame(width: Self.thumb, height: Self.thumb)
            .offset(x: x - Self.thumb / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let raw = ((value.location.x - Self.thumb / 2) / width * 100).rounded()
                        dragging = (limit, min(max(raw, limit.range.lowerBound), limit.range.upperBound))
                    }
                    .onEnded { _ in
                        if let dragging { onChange(limit, Int(dragging.percent)) }
                        dragging = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(limit == .discharge ? "Discharge limit" : "Charge limit")
            .accessibilityValue("\(Int(percent(limit))) percent")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 1 : -1
                let next = min(max(percent(limit) + step, limit.range.lowerBound), limit.range.upperBound)
                onChange(limit, Int(next))
            }
    }

    private static let space = "LimitSlider"
}
