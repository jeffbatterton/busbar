import BusbarCore
import SwiftUI

struct DropdownView: View {
    let monitor: Monitor
    let openSettings: () -> Void

    /// Rows are a fixed height with roomy gaps, so the lists read relaxed rather than packed.
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = monitor.snapshot {
                header(snapshot)
                Divider()
                if monitor.settings.historyClient != nil { batteryHistory }
                section("Power in", total: snapshot.wattsIn) {
                    inputRow("Solar", icon: .sunLight, watts: snapshot.solarWatts)
                    inputRow("Shore power", icon: .evPlugCharging, watts: snapshot.acInWatts,
                             detail: snapshot.shorePowerConnected ? "Connected" : nil)
                    inputRow("Alternator / DC", icon: .car, watts: snapshot.otherInWatts)
                }
                section("Power out", total: snapshot.wattsOut) {
                    outputRow("High voltage", icon: .plugTypeA, output: .ac,
                              watts: snapshot.acOutWatts, isOn: snapshot.acOutputOn)
                    outputRow("Low voltage", icon: .plugTypeC, output: .dc12V,
                              watts: snapshot.dc12VOutWatts, isOn: snapshot.dc12VOutputOn)
                }
                batteries(snapshot)
                if !snapshot.warnings.isEmpty { warnings(snapshot.warnings) }
            } else {
                placeholder
            }
            Divider()
            footer
        }
        // Wide side margins leave room for the pack transfer bracket left of the battery icons.
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .frame(width: 312)
    }

    // MARK: Sections

    private func header(_ s: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("\(Int(s.stateOfCharge.rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(flowTitle(s)).font(.headline).foregroundStyle(flowColor(s))
                    if let remaining = remainingText(s) {
                        Text(remaining).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            ChargeBar(level: s.stateOfCharge / 100, color: levelColor,
                      dischargeLimit: s.dischargeLimit / 100, chargeLimit: s.chargeLimit / 100)
        }
    }

    /// The charge live, over today or over this week, from the history logger.
    private var batteryHistory: some View {
        @Bindable var settings = monitor.settings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battery").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Range", selection: $settings.historyRange) {
                    Text("Live").tag(HistoryRange.live)
                    Text("24h").tag(HistoryRange.today)
                    Text("7d").tag(HistoryRange.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            if monitor.history.readings.isEmpty, let error = monitor.historyError {
                Text("History unavailable: \(error)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                HistoryChart(history: monitor.history, range: settings.historyRange,
                             lowThreshold: settings.lowThreshold, criticalThreshold: settings.criticalThreshold)
            }
        }
    }

    private func section<Content: View>(_ title: String, total: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(watts(total)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            content()
        }
    }

    /// Yellow icon while power is coming in.
    private func inputRow(_ title: String, icon: Iconoir, watts value: Int, detail: String? = nil) -> some View {
        row(title, icon: icon, lit: value > 0 ? .powerIn : nil, watts: value, detail: detail)
    }

    /// Blue icon while the output is switched on, grey when off. Clicking it switches the output.
    private func outputRow(_ title: String, icon: Iconoir, output: PowerOutput, watts value: Int,
                           isOn: Bool) -> some View {
        row(title, icon: icon, lit: isOn ? .blue : nil, watts: value,
            toggle: ToggleAction(help: "Turn \(title.lowercased()) \(isOn ? "off" : "on")",
                                 isBusy: monitor.switchingOutputs.contains(output)) {
                monitor.setOutput(output, on: !isOn)
            })
    }

    private func row(_ title: String, icon: Iconoir, lit: Color?, watts value: Int,
                     detail: String? = nil, toggle: ToggleAction? = nil) -> some View {
        HStack(spacing: 8) {
            if let toggle {
                ToggleIcon(icon: StatusIcon(icon: icon, lit: lit), action: toggle)
            } else {
                StatusIcon(icon: icon, lit: lit)
            }
            Text(title)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(watts(value)).monospacedDigit()
                .foregroundStyle(value == 0 ? .tertiary : .primary)
        }
        .font(.callout)
        .frame(height: Self.rowHeight)
    }

    private func batteries(_ s: PowerSnapshot) -> some View {
        // Main is first and Extra second; the transfer only shows while both are online.
        let transfer = s.batteries.count == 2 && s.batteries.allSatisfy(\.isAvailable) ? s.packTransferWatts : 0
        let sender = transfer > 0 ? 1 : 0
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Text("Batteries").font(.subheadline.weight(.semibold))
            TimelineView(.animation(paused: transfer == 0)) { context in
                let pulse = PackTransferPulse(at: context.date)
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(Array(s.batteries.enumerated()), id: \.element.id) { index, battery in
                        batteryRow(battery,
                                   sending: transfer != 0 && index == sender ? transfer : nil,
                                   landingGlow: transfer != 0 && index != sender ? pulse.landingGlow : 0)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if transfer != 0 {
                        PackTransferBracket(pulse: pulse, downward: transfer < 0)
                            .frame(width: 12, height: Self.rowHeight + Self.rowSpacing)
                            .offset(x: -13, y: Self.rowHeight / 2)
                    }
                }
            }
        }
    }

    /// `sending` is the pack transfer when this pack is the one sending it.
    private func batteryRow(_ battery: PowerSnapshot.Battery, sending: Int?, landingGlow: Double) -> some View {
        HStack(spacing: 8) {
            StatusIcon(icon: .batteryIndicator, lit: battery.isAvailable ? .green : .red,
                       intensity: 1 + landingGlow)
            Text(battery.name)
            if let sending {
                // Extra sits below Main, so the arrow points at the pack receiving the power.
                HStack(spacing: 2) {
                    (sending > 0 ? Iconoir.dotArrowUp : .dotArrowDown).image(size: 13)
                    Text(watts(abs(sending)))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
                .monospacedDigit()
            }
            Spacer()
            if let temp = battery.temperature {
                Text("\(Int((temp * 9 / 5 + 32).rounded()))°F").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(batteryValue(battery))
                .foregroundStyle(battery.isAvailable ? .primary : .secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.callout)
        .frame(height: Self.rowHeight)
    }

    private func warnings(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Label { Text(item) } icon: { Iconoir.warningTriangleSolid.image(size: 15) }
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var placeholder: some View {
        HStack {
            if monitor.lastError == nil {
                ProgressView().controlSize(.small)
                Text("Connecting to Delta Pro…").foregroundStyle(.secondary)
            } else {
                Label { Text(monitor.lastError ?? "") } icon: { Iconoir.xmarkCircle.image(size: 15) }
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(updatedText).font(.caption).foregroundStyle(monitor.isStale ? .orange : .secondary)
                }
                if monitor.isSimulated {
                    Text("Simulated data").font(.caption).foregroundStyle(.purple)
                } else if let error = monitor.lastError, monitor.snapshot != nil {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
            Button { monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh now")
                .disabled(monitor.isRefreshing)
            Button {
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Busbar")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Formatting

    private func batteryValue(_ battery: PowerSnapshot.Battery) -> String {
        guard battery.isAvailable else { return "Unavailable" }
        return battery.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "Connected"
    }

    private var levelColor: Color {
        switch monitor.batteryLevel {
        case .normal: .green
        case .low: .yellow
        case .critical: .red
        }
    }

    private func flowTitle(_ s: PowerSnapshot) -> String {
        switch s.flow {
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .idle: "Idle"
        }
    }

    private func flowColor(_ s: PowerSnapshot) -> Color {
        s.flow == .charging ? .green : .primary
    }

    private func remainingText(_ s: PowerSnapshot) -> String? {
        switch s.flow {
        case .charging: s.minutesToFull.map { "\(AlertEngine.duration($0)) to full" }
        case .discharging: s.minutesToEmpty.map { "\(AlertEngine.duration($0)) left" }
        case .idle: nil
        }
    }

    private var updatedText: String {
        guard let date = monitor.lastUpdate else { return "Not updated yet" }
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(AlertEngine.duration(seconds / 60)) ago"
    }

    private func watts(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.2f kW", Double(value) / 1000) : "\(value) W"
    }
}

/// A row icon that looks lit up: drawn in `lit` with a soft glow of the same color,
/// or plain grey when `lit` is nil.
private struct StatusIcon: View {
    let icon: Iconoir
    let lit: Color?
    var intensity: Double = 1

    var body: some View {
        icon.image(size: 16)
            .foregroundStyle(lit ?? .secondary)
            .glow(lit ?? .clear, intensity: intensity)
            .frame(width: 18)
    }
}

/// Where the pulse is along the bracket joining the two packs: a short dash that runs
/// from the sending pack's icon to the receiving pack's, over and over.
private struct PackTransferPulse {
    static let period = 1.6
    static let dash = 0.16
    /// Runs past 1 by the dash length so the dash slides fully off the end.
    let progress: Double

    init(at date: Date) {
        progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            / Self.period * (1 + Self.dash)
    }

    /// How much brighter the receiving icon glows, 0–0.8, peaking as the dash lands.
    var landingGlow: Double { 0.8 * max(0, 1 - abs(progress - 1.06) / 0.12) }
}

/// A faint green bracket in the left margin, from one pack icon round to the other,
/// with the pulse running along it in the direction the power is going.
private struct PackTransferBracket: View {
    let pulse: PackTransferPulse
    let downward: Bool

    var body: some View {
        ZStack {
            Bracket(downward: downward).stroke(.green.opacity(0.18), lineWidth: 1.5)
            Bracket(downward: downward)
                .trim(from: max(0, pulse.progress - PackTransferPulse.dash), to: min(1, pulse.progress))
                .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .glow(.green, intensity: 0.8)
        }
    }

    /// Runs from the sending end to the receiving end, so trimming moves the dash that way.
    private struct Bracket: Shape {
        let downward: Bool

        func path(in rect: CGRect) -> Path {
            let left = rect.minX + 1.5, radius = 5.0
            let (from, to) = downward ? (rect.minY, rect.maxY) : (rect.maxY, rect.minY)
            let step = downward ? radius : -radius
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: from))
            path.addLine(to: CGPoint(x: left + radius, y: from))
            path.addQuadCurve(to: CGPoint(x: left, y: from + step), control: CGPoint(x: left, y: from))
            path.addLine(to: CGPoint(x: left, y: to - step))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: to), control: CGPoint(x: left, y: to))
            path.addLine(to: CGPoint(x: rect.maxX, y: to))
            return path
        }
    }
}

struct ToggleAction {
    let help: String
    let isBusy: Bool
    let perform: () -> Void
}

/// A status icon that switches its output when clicked, with a faint ring on hover.
private struct ToggleIcon: View {
    let icon: StatusIcon
    let action: ToggleAction
    @State private var isHovered = false

    var body: some View {
        Button(action: action.perform) { icon }
            .buttonStyle(.plain)
            .contentShape(Circle().inset(by: -4))
            .background {
                Circle()
                    .strokeBorder(.primary.opacity(isHovered && !action.isBusy ? 0.2 : 0), lineWidth: 1)
                    .frame(width: 24, height: 24)
            }
            .onHover { isHovered = $0 }
            .pointerStyle(action.isBusy ? nil : .link)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .disabled(action.isBusy)
            .help(action.help)
            .accessibilityLabel(action.help)
    }
}

/// The battery level bar under the percentage, lit in the level color. Charge below the
/// discharge limit is striped in the level color, and the track above the charge limit is
/// striped too, so the solid part is the charge you can use. A line marks each limit.
private struct ChargeBar: View {
    let level: Double
    let color: Color
    var dischargeLimit: Double = 0
    var chargeLimit: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let level = min(1, max(0, level))
            let reserve = min(level, dischargeLimit)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                ZStack(alignment: .leading) {
                    if reserve > 0 {
                        ZStack {
                            color.opacity(0.3)
                            Stripes().fill(color)
                        }
                        .frame(width: width * reserve)
                        .clipped()
                    }
                    if chargeLimit < 1 {
                        Stripes().fill(Color.primary.opacity(0.22))
                            .frame(width: width * (1 - chargeLimit))
                            .clipped()
                            .offset(x: width * chargeLimit)
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipShape(Capsule())
                if level > dischargeLimit {
                    solid(height: height)
                        .fill(color)
                        .frame(width: dischargeLimit > 0 ? width * (level - dischargeLimit)
                                                         : max(height, width * level))
                        .offset(x: width * dischargeLimit)
                        .glow(color, intensity: 0.5)
                }
                ForEach([dischargeLimit, chargeLimit].filter { $0 > 0 && $0 < 1 }, id: \.self) { limit in
                    limitLine(height: height).offset(x: width * limit - 0.5)
                }
            }
        }
        .frame(height: 6)
    }

    /// A 1 pt line marking a limit, running 3 pt past the bar above and below.
    private func limitLine(height: Double) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.6))
            .frame(width: 1, height: height + 6)
            .frame(height: height)
    }

    /// Rounded at both ends from empty; only at the level end when it starts at the discharge limit.
    private func solid(height: Double) -> UnevenRoundedRectangle {
        let leading = dischargeLimit > 0 ? 0 : height / 2
        return UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading,
                                      bottomTrailingRadius: height / 2, topTrailingRadius: height / 2)
    }
}

/// Diagonal stripes rising to the right, a stripe and a gap of equal width. They overhang
/// the rect so its corners are covered; clip them to stop at its edges.
private struct Stripes: Shape {
    var period: Double = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + period / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + period / 2 + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.closeSubpath()
            x += period
        }
        return path
    }
}

extension Color {
    /// Warm gold for incoming power: as saturated as the system blue and green beside it,
    /// but warmer than system yellow so it doesn't read as the low-battery warning.
    static let powerIn = Color(red: 1.0, green: 0.78, blue: 0.24)
}

extension View {
    /// A soft two-layer glow in `color`, so the view looks lit up.
    func glow(_ color: Color, intensity: Double = 1) -> some View {
        shadow(color: color.opacity(0.7 * intensity), radius: 2)
            .shadow(color: color.opacity(0.4 * intensity), radius: 5)
    }
}
