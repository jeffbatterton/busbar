import BusbarCore
import SwiftUI

struct DropdownView: View {
    let monitor: Monitor
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = monitor.snapshot {
                header(snapshot)
                Divider()
                section("Power in", total: snapshot.wattsIn) {
                    inputRow("Solar", icon: "sun.max", watts: snapshot.solarWatts)
                    inputRow("Shore power", icon: "powerplug", watts: snapshot.acInWatts,
                             detail: snapshot.shorePowerConnected ? "Connected" : nil)
                    inputRow("Alternator / DC", icon: "car", watts: snapshot.otherInWatts)
                }
                section("Power out", total: snapshot.wattsOut) {
                    outputRow("High voltage", icon: "poweroutlet.type.b",
                              watts: snapshot.acOutWatts, isOn: snapshot.acOutputOn)
                    outputRow("Low voltage", icon: "bolt.car",
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
        .padding(16)
        .frame(width: 300)
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
            ChargeBar(level: s.stateOfCharge / 100, color: levelColor)
        }
    }

    private func section<Content: View>(_ title: String, total: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(watts(total)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            content()
        }
    }

    /// Green icon while power is coming in.
    private func inputRow(_ title: String, icon: String, watts value: Int, detail: String? = nil) -> some View {
        row(title, icon: icon, lit: value > 0 ? .green : nil, watts: value, detail: detail)
    }

    /// Blue icon while the output is switched on, grey when off.
    private func outputRow(_ title: String, icon: String, watts value: Int, isOn: Bool) -> some View {
        row(title, icon: icon, lit: isOn ? .blue : nil, watts: value)
    }

    private func row(_ title: String, icon: String, lit: Color?, watts value: Int,
                     detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            StatusIcon(name: icon, lit: lit)
            Text(title)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(watts(value)).monospacedDigit()
                .foregroundStyle(value == 0 ? .tertiary : .primary)
        }
        .font(.callout)
    }

    private func batteries(_ s: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Batteries").font(.subheadline.weight(.semibold))
            ForEach(s.batteries) { battery in
                HStack(spacing: 8) {
                    StatusIcon(name: "minus.plus.batteryblock", lit: battery.isAvailable ? .green : .red)
                    Text(battery.name)
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
            }
        }
    }

    private func warnings(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "exclamationmark.triangle.fill")
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
                Label(monitor.lastError ?? "", systemImage: "exclamationmark.triangle")
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
    let name: String
    let lit: Color?

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(lit ?? .secondary)
            .glow(lit ?? .clear)
            .frame(width: 18)
    }
}

/// The battery level bar under the percentage, lit in the level color.
private struct ChargeBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(geometry.size.height, geometry.size.width * min(1, max(0, level))))
                    .glow(color, intensity: 0.5)
            }
        }
        .frame(height: 6)
    }
}

extension View {
    /// A soft two-layer glow in `color`, so the view looks lit up.
    func glow(_ color: Color, intensity: Double = 1) -> some View {
        shadow(color: color.opacity(0.7 * intensity), radius: 2)
            .shadow(color: color.opacity(0.4 * intensity), radius: 5)
    }
}
