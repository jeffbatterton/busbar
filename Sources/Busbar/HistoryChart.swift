import BusbarCore
import Charts
import SwiftUI

/// The charge live, over today or over this week: a smooth line on a fixed 0–100% scale, colored by
/// height from green down through yellow at the low threshold to red at critical, gold bands
/// where power was coming in, and a faint dashed line at the low battery threshold. The line
/// runs straight on across the few minutes the logger sometimes misses; where the Delta Pro
/// was offline it breaks, over a hatched band, with a dotted line from where it left off to
/// where it came back.
///
/// Large, it fills the full-screen window: gridlines every 25% with labels, more time ticks,
/// the charge limits shaded, a label on the low battery line, and watts in the tooltip.
struct HistoryChart: View {
    let history: ChargeHistory
    let range: HistoryRange
    let lowThreshold: Double
    let criticalThreshold: Double
    var isLarge = false
    /// The discharge and charge limits, shaded beyond when large.
    var limits: ClosedRange<Double>?

    static let height: CGFloat = 92
    @State private var hovered: ChargeReading?
    /// The offline stretch under the pointer, and where in it the pointer is.
    @State private var hoveredOutage: (outage: DateInterval, at: Date)?

    private var window: DateInterval { range.window(containing: .now) }

    private var readings: [ChargeReading] {
        let window = window
        return history.readings.filter { $0.time >= window.start && $0.time < window.end }
    }

    var body: some View {
        let readings = readings
        let now = Date.now
        let outages = outages(now: now)
        // A line per stretch the Delta Pro was online, each smoothed on its own.
        let segments = ChargeHistory.runs(readings, gap: ChargeHistory.offlineGap)
            .map { ChargeHistory.smoothed($0, bucket: range.bucket) }
        let top = segments.joined().map(\.stateOfCharge).max() ?? 0
        Chart {
            ForEach(Array(ChargeHistory.chargingBands(readings).enumerated()), id: \.offset) { _, band in
                RectangleMark(xStart: .value("Time", band.start), xEnd: .value("Time", band.end),
                              yStart: .value("Charge", 0), yEnd: .value("Charge", 100))
                    .foregroundStyle(Color.powerIn.opacity(0.11))
            }
            if isLarge, let limits {
                ForEach([(0, limits.lowerBound), (limits.upperBound, 100)].filter { $0.0 < $0.1 }, id: \.0) { band in
                    RectangleMark(xStart: .value("Time", window.start), xEnd: .value("Time", window.end),
                                  yStart: .value("Charge", band.0), yEnd: .value("Charge", band.1))
                        .foregroundStyle(.white.opacity(0.035))
                }
                ForEach([limits.lowerBound, limits.upperBound].filter { $0 > 0 && $0 < 100 }, id: \.self) { limit in
                    RuleMark(y: .value("Charge", limit))
                        .foregroundStyle(.white.opacity(0.14))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            ForEach(isLarge ? [100, 75, 50, 25, 0] : [100, 50, 0], id: \.self) { level in
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
                .annotation(position: .top, alignment: .leading) {
                    if isLarge {
                        Text("Low battery \(Int(lowThreshold))%")
                            .font(.system(size: 11)).foregroundStyle(Color.yellow.opacity(0.5))
                    }
                }

            ForEach(Array(segments.enumerated()), id: \.offset) { index, points in
                let levels = points.map(\.stateOfCharge)
                let high = levels.max() ?? 0
                let area = gradient(from: 0, to: high) { top > 0 ? 0.24 * $0 / top : 0 }
                let line = gradient(from: levels.min() ?? 0, to: high)
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", point.time), yStart: .value("Charge", 0),
                             yEnd: .value("Charge", point.stateOfCharge), series: .value("Segment", "area \(index)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(area)
                    LineMark(x: .value("Time", point.time), y: .value("Charge", point.stateOfCharge),
                             series: .value("Segment", "line \(index)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(line)
                        .lineStyle(StrokeStyle(lineWidth: isLarge ? 3 : 2, lineCap: .round, lineJoin: .round))
                }
            }
            // Across each outage, a dotted line from where the charge left off to where it came
            // back, with a small open dot at each end.
            ForEach(Array(zip(segments, segments.dropFirst()).enumerated()), id: \.offset) { index, pair in
                if let from = pair.0.last, let to = pair.1.first {
                    ForEach([from, to], id: \.time) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Charge", point.stateOfCharge),
                                 series: .value("Segment", "bridge \(index)"))
                            .foregroundStyle(color(at: (from.stateOfCharge + to.stateOfCharge) / 2).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: isLarge ? 2 : 1.5, lineCap: .round, dash: [0.1, 4]))
                    }
                    ForEach([from, to], id: \.time) { point in
                        PointMark(x: .value("Time", point.time), y: .value("Charge", point.stateOfCharge))
                            .symbol {
                                let size: CGFloat = isLarge ? 7 : 5
                                Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: size, height: size)
                                    .overlay(Circle().stroke(color(at: point.stateOfCharge), lineWidth: 1.5))
                            }
                    }
                }
            }

            if let hoveredOutage {
                RuleMark(x: .value("Time", hoveredOutage.at)).foregroundStyle(.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
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
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let level = value.as(Int.self) {
                        Text("\(level)%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis(isLarge ? .visible : .hidden)
        .chartLegend(.hidden)
        .chartXAxis { timeAxis }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ForEach(outages, id: \.shown.start) { outage in
                        if let start = proxy.position(forX: outage.shown.start), let end = proxy.position(forX: outage.shown.end) {
                            Hatching().frame(width: max(0, end - start), height: frame.height)
                                .position(x: frame.minX + (start + end) / 2, y: frame.midY)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        hoveredOutage = nil
                        guard case .active(let location) = phase, let plot = proxy.plotFrame,
                              let time: Date = proxy.value(atX: location.x - geometry[plot].minX)
                        else { hovered = nil; return }
                        if let outage = outages.first(where: { $0.shown.start < time && time < $0.shown.end }) {
                            hovered = nil
                            hoveredOutage = (outage.outage, time)
                            return
                        }
                        guard let last = readings.last, time <= last.time.addingTimeInterval(window.duration / 40)
                        else { hovered = nil; return }
                        hovered = readings.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
                    }
                if let hoveredOutage, let plot = proxy.plotFrame, let x = proxy.position(forX: hoveredOutage.at) {
                    let frame = geometry[plot]
                    offlineTooltip(for: hoveredOutage.outage, isOngoing: hoveredOutage.outage.end == now)
                        .fixedSize()
                        .position(x: min(frame.maxX - 70, max(frame.minX + 70, frame.minX + x)), y: frame.midY)
                }
                if let hovered, let plot = proxy.plotFrame,
                   let x = proxy.position(forX: hovered.time), let y = proxy.position(forY: hovered.stateOfCharge) {
                    let frame = geometry[plot]
                    tooltip(for: hovered, isLatest: hovered == readings.last)
                        .fixedSize()
                        .position(x: min(frame.maxX - 60, max(frame.minX + 50, frame.minX + x)),
                                  y: frame.minY + max(4, y) - (isLarge ? 34 : 18))
                }
            }
        }
        .frame(height: isLarge ? nil : Self.height)
    }

    /// The offline stretches in this window, cut to it and to now. Found from all the
    /// readings, so one that began before the window still shows.
    private func outages(now: Date) -> [(shown: DateInterval, outage: DateInterval)] {
        let window = window
        let end = min(window.end, now)
        return ChargeHistory.outages(history.readings, now: now).compactMap { outage in
            let start = max(outage.start, window.start), stop = min(outage.end, end)
            return start < stop ? (DateInterval(start: start, end: stop), outage) : nil
        }
    }

    private func dot(at reading: ChargeReading) -> some ChartContent {
        PointMark(x: .value("Time", reading.time), y: .value("Charge", reading.stateOfCharge))
            .symbol {
                let size: CGFloat = isLarge ? 11 : 8
                Circle().fill(color(at: reading.stateOfCharge)).frame(width: size, height: size)
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

    /// Live: each whole hour, clear of the edges. Today: 12am 6am 12pm 6pm, or every three
    /// hours when large. This week: the day names, centered in each day.
    private var timeAxis: some AxisContent {
        let window = window
        let values: [Date] = switch range {
        case .live:
            (0...6).map { Calendar.current.dateInterval(of: .hour, for: window.start)!.end.addingTimeInterval(Double($0) * 3600) }
                .filter { $0.timeIntervalSince(window.start) > 900 && window.end.timeIntervalSince($0) > 900 }
        case .today:
            (0..<(isLarge ? 8 : 4)).map { Calendar.current.date(byAdding: .hour, value: $0 * (isLarge ? 3 : 6), to: window.start)! }
        case .week: (0..<7).map { dayStart($0).addingTimeInterval(12 * 3600) }
        }
        return AxisMarks(values: values) { value in
            AxisValueLabel(anchor: range == .today && value.index == 0 ? .topLeading : .top) {
                if let date = value.as(Date.self) {
                    let isToday = range == .week && Calendar.current.isDateInToday(date)
                    Text(range == .week ? date.formatted(.dateTime.weekday(.abbreviated)) : hourLabel(date))
                        .font(.system(size: isLarge ? 11 : 10))
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

    private func offlineTooltip(for outage: DateInterval, isOngoing: Bool) -> some View {
        let start = outage.start.formatted(date: .omitted, time: .shortened)
        let span = isOngoing ? "since \(start)" : "\(start) – \(outage.end.formatted(date: .omitted, time: .shortened))"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("Offline").fontWeight(.semibold)
                Text(span).foregroundStyle(.secondary)
            }
            Text("No readings for \(AlertEngine.duration(Int(outage.duration / 60)))")
                .font(.system(size: isLarge ? 11 : 10)).foregroundStyle(.secondary)
        }
        .font(.system(size: isLarge ? 13 : 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.18), lineWidth: 0.5))
        .allowsHitTesting(false)
    }

    private func tooltip(for reading: ChargeReading, isLatest: Bool) -> some View {
        let time = isLatest ? "Now"
            : range == .week ? reading.time.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : reading.time.formatted(date: .omitted, time: .shortened)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("\(Int(reading.stateOfCharge.rounded()))%").fontWeight(.semibold).monospacedDigit()
                Text(time + (reading.isCharging ? " · charging" : "")).foregroundStyle(.secondary)
            }
            if isLarge {
                HStack(spacing: 0) {
                    if reading.wattsIn > 0 {
                        Text("\(reading.wattsIn) W in").foregroundStyle(Color.powerIn)
                        Text(" · ")
                    }
                    Text("\(reading.wattsOut) W out")
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.system(size: isLarge ? 13 : 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.18), lineWidth: 0.5))
        .allowsHitTesting(false)
    }
}

/// Faint diagonal stripes for when the Delta Pro was offline.
private struct Hatching: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.025)))
            var stripes = Path()
            for x in stride(from: -size.height, to: size.width, by: 6) {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(stripes, with: .color(.white.opacity(0.08)), lineWidth: 1.5)
        }
        .clipped()
    }
}
