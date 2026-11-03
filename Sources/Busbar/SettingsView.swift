import BusbarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let monitor: Monitor

    @State private var testState: TestState = .idle

    enum TestState {
        case idle, testing
        case success([EcoFlowDevice])
        case failure(String)
    }

    @State private var pane: Pane = .account

    enum Pane: String, CaseIterable, Identifiable {
        case account, history, alerts, connection, general
        var id: Self { self }

        var title: String {
            switch self {
            case .account: "EcoFlow account"
            case .history: "Battery history"
            case .alerts: "Battery alerts"
            case .connection: "Connection"
            case .general: "General"
            }
        }

        var icon: String {
            switch self {
            case .account: "key"
            case .history: "chart.xyaxis.line"
            case .alerts: "bell"
            case .connection: "antenna.radiowaves.left.and.right"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { content(for: pane) }
                .formStyle(.grouped)
                .navigationTitle(pane.title)
        }
        .frame(width: 660, height: 420)
        .onChange(of: settings.credentials) { monitor.refreshNow() }
        .onChange(of: settings.useSimulatedData) { monitor.refreshNow() }
        .onChange(of: settings.pollInterval) { monitor.refreshNow() }
        .onChange(of: settings.historyURL) { monitor.resetHistory() }
        .onChange(of: settings.historyToken) { monitor.resetHistory() }
    }

    @ViewBuilder private func content(for pane: Pane) -> some View {
        switch pane {
        case .account:
            Section {
                TextField("Access key", text: $settings.accessKey)
                SecureField("Secret key", text: $settings.secretKey)
                TextField("Delta Pro serial number", text: $settings.serialNumber)
                Toggle("Use simulated data", isOn: $settings.useSimulatedData)
                HStack {
                    Button("Test connection", action: testConnection)
                        .disabled(settings.accessKey.isEmpty || settings.secretKey.isEmpty)
                    testResult
                }
            } footer: {
                Text("Keys come from developer.ecoflow.com → Access Management. They're stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .history:
            Section {
                TextField("Logger address", text: $settings.historyURL)
                SecureField("Read token", text: $settings.historyToken)
            } footer: {
                Text("The history logger records the charge every minute, even while this Mac is asleep. The token is stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .alerts:
            Section {
                threshold("Low", value: $settings.lowThreshold, range: 5...80, color: .yellow)
                threshold("Critical", value: $settings.criticalThreshold, range: 1...79, color: .red)
            }
            Section {
                Toggle("Notify when battery is low", isOn: $settings.notifyBattery)
                Toggle("Notify about faults and warnings", isOn: $settings.notifyWarnings)
                Toggle("Notify when shore power connects or drops", isOn: $settings.notifyShorePower)
            }
        case .connection:
            Section {
                Picker("Check every", selection: $settings.pollInterval) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Offline after", selection: $settings.offlineMinutes) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                Toggle("Notify when the bus goes offline", isOn: $settings.notifyOffline)
            }
        case .general:
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
    }

    private func threshold(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           color: Color) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range, step: 1).tint(color)
                Text("\(Int(value.wrappedValue))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let devices):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(devices) { device in
                    Button {
                        settings.serialNumber = device.serialNumber
                    } label: {
                        Text("\(device.name) · \(device.serialNumber)\(device.online ? "" : " (offline)")")
                    }
                    .buttonStyle(.link)
                    .help("Use this device")
                }
            }
            .font(.caption)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private func testConnection() {
        testState = .testing
        let client = EcoFlowClient(credentials: settings.credentials)
        Task {
            do {
                testState = .success(try await client.devices())
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
