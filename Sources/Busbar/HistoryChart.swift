import BusbarCore
import Charts
import SwiftUI

/// The charge over today or this week: a smooth line on a fixed 0–100% scale, colored by
/// height from green down through yellow at the low threshold to red at critical, gold bands
/// where power was coming in, and a faint dashed line at the low battery threshold. The line
/// runs straight on across gaps where the logger missed readings.
struct HistoryChart: View {
    let history: ChargeHistory
    let range: HistoryRange
    let lowThreshold: Double
    let criticalThreshold: Double

    static let height: CGFloat = 92
    @State private var hovered: ChargeReading?

    private var window: DateInterval { range.window(containing: .now) }

    private var readings: [ChargeReading] {
        let window = window
        return history.readings.filter { $0.time >= window.start && $0.time < window.end }
    }

    var body: some View {
        let readings = readings
        let points = ChargeHistory.smoothed(readings, bucket: range.bucket)
        let levels = points.map(\.stateOfCharge)
        let top = levels.max() ?? 0
        let area = gradient(from: 0, to: top) { top > 0 ? 0.24 * $0 / top : 0 }
        let line = gradient(from: levels.min() ?? 0, to: top)
        Chart {
            ForEach(Array(ChargeHistory.chargingBands(readings).enumerated()), id: \.offset) { _, band in
                RectangleMark(xStart: .value("Time", band.start), xEnd: .value("Time", band.end),
                              yStart: .value("Charge", 0), yEnd: .value("Charge", 100))
                    .foregroundStyle(Color.powerIn.opacity(0.11))
            }
            ForEach([100, 50, 0], id: \.self) { level in
                RuleMark(y: .value("Charge", level))
                    .foregroundStyle(.white.opacity(level == 0 ? 0.16 : 0.07))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if range == .week {
                ForEach(1..<7, id: \.self) { day in
                    RuleMark(x: .value("Time", dayStart(day)))
                        .foregroundStyle(.white.opacity(0.07))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            RuleMark(y: .value("Charge", lowThreshold))
                .foregroundStyle(Color.yellow.opacity(0.22))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.time), yStart: .value("Charge", 0),
                         yEnd: .value("Charge", point.stateOfCharge))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(area)
                LineMark(x: .value("Time", point.time), y: .value("Charge", point.stateOfCharge))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(line)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if let hovered {
                RuleMark(x: .value("Time", hovered.time)).foregroundStyle(.white.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                dot(at: hovered)
            }
            if let last = readings.last { dot(at: last) }
        }
        .chartXScale(domain: window.start...window.end)
        .chartYScale(domain: 0...100)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis { timeAxis }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                              let time: Date = proxy.value(atX: location.x - geometry[plot].minX),
                              let last = readings.last, time <= last.time.addingTimeInterval(window.duration / 40)
                        else { hovered = nil; return }
                        hovered = readings.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
                    }
                if let hovered, let plot = proxy.plotFrame,
                   let x = proxy.position(forX: hovered.time), let y = proxy.position(forY: hovered.stateOfCharge) {
                    let frame = geometry[plot]
                    tooltip(for: hovered, isLatest: hovered == readings.last)
                        .fixedSize()
                        .position(x: min(frame.maxX - 60, max(frame.minX + 50, frame.minX + x)),
                                  y: frame.minY + max(4, y) - 18)
                }
            }
        }
        .frame(height: Self.height)
    }

    private func dot(at reading: ChargeReading) -> some ChartContent {
        PointMark(x: .value("Time", reading.time), y: .value("Charge", reading.stateOfCharge))
            .symbol {
                Circle().fill(color(at: reading.stateOfCharge)).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
    }

    /// The line's colors by charge: red up to critical, yellow at low, green from 20 points
    /// above low, blended in between.
    private var levelColors: [(level: Double, color: Color)] {
        [(criticalThreshold, .red), (lowThreshold, .yellow), (min(100, lowThreshold + 20), .green)]
    }

    private func color(at level: Double) -> Color {
        let colors = levelColors
        guard let upper = colors.firstIndex(where: { level < $0.level }) else { return colors.last!.color }
        guard upper > 0 else { return colors[0].color }
        let (low, high) = (colors[upper - 1], colors[upper])
        return low.color.mix(with: high.color, by: (level - low.level) / (high.level - low.level))
    }

    /// The level colors, bottom to top, for a series spanning `low...high`: Swift Charts
    /// stretches a series' gradient over the series' own bounds, not the plot's.
    private func gradient(from low: Double, to high: Double,
                          opacity: (Double) -> Double = { _ in 1 }) -> LinearGradient {
        let levels = [low] + levelColors.map(\.level).filter { $0 > low && $0 < high } + [high]
        let stops = levels.map { level in
            Gradient.Stop(color: color(at: level).opacity(opacity(level)),
                          location: high > low ? (level - low) / (high - low) : 0)
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    private func dayStart(_ day: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: day, to: window.start)!
    }

    /// Today: 12am 6am 12pm 6pm. This week: the day names, centered in each day.
    private var timeAxis: some AxisContent {
        let values: [Date] = range == .today
            ? (0..<4).map { Calendar.current.date(byAdding: .hour, value: $0 * 6, to: window.start)! }
            : (0..<7).map { dayStart($0).addingTimeInterval(12 * 3600) }
        return AxisMarks(values: values) { value in
            AxisValueLabel(anchor: range == .today && value.index == 0 ? .topLeading : .top) {
                if let date = value.as(Date.self) {
                    let isToday = range == .week && Calendar.current.isDateInToday(date)
                    Text(range == .today ? hourLabel(date) : date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? .secondary : .tertiary)
                }
            }
        }
    }

    private func hourLabel(_ date: Date) -> String {
        // "12 AM" → "12am"; the space before AM/PM is a narrow no-break space.
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))).filter { !$0.isWhitespace }.lowercased()
    }

    private func tooltip(for reading: ChargeReading, isLatest: Bool) -> some View {
        let time = isLatest ? "Now"
            : range == .week ? reading.time.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : reading.time.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 5) {
            Text("\(Int(reading.stateOfCharge.rounded()))%").fontWeight(.semibold).monospacedDigit()
            Text(time + (reading.isCharging ? " · charging" : "")).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.18), lineWidth: 0.5))
        .allowsHitTesting(false)
    }
}
