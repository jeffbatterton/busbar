import BusbarCore
import SwiftUI

struct DropdownView: View {
    let monitor: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = monitor.snapshot {
                header(snapshot)
                Divider()
                section("Power in", total: snapshot.wattsIn) {
                    row("Solar", icon: "sun.max", watts: snapshot.solarWatts)
                    row("Shore power", icon: "powerplug", watts: snapshot.acInWatts,
                        detail: snapshot.shorePowerConnected ? "Connected" : nil)
                    row("Alternator / DC", icon: "car", watts: snapshot.otherInWatts)
                }
                section("Power out", total: snapshot.wattsOut) {
                    row("AC outlets", icon: "poweroutlet.type.b", watts: snapshot.acOutWatts)
                    row("12 V", icon: "bolt.car", watts: snapshot.dc12VOutWatts)
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
            HStack(alignment: .firstTextBaseline) {
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
            Gauge(value: s.stateOfCharge, in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(levelColor)
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

    private func row(_ title: String, icon: String, watts value: Int, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
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
                    Image(systemName: "minus.plus.batteryblock").frame(width: 18).foregroundStyle(.secondary)
                    Text(battery.name)
                    Spacer()
                    if let temp = battery.temperature {
                        Text("\(Int((temp * 9 / 5 + 32).rounded()))°F").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(battery.stateOfCharge.map { "\(Int($0.rounded()))%" } ?? "Connected")
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
                openWindow(id: "settings")
                NSApp.activate()
            } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Busbar")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Formatting

    private var levelColor: Color {
        switch monitor.batteryLevel {
        case .normal: .green
        case .low: .orange
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
