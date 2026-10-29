import AppKit
import BusbarCore
import Foundation
import Observation
import UserNotifications

/// Polls the active power source, keeps the latest snapshot, and fires notifications.
@MainActor @Observable
final class Monitor {
    private(set) var snapshot: PowerSnapshot?
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    let settings: AppSettings
    private var alerts = AlertEngine()
    private var loop: Task<Void, Never>?
    /// Tweak with e.g. `defaults write com.batterton.busbar simulatorSOC -float 10`
    /// and `defaults write com.batterton.busbar simulatorScenario charging`,
    /// or `defaults write com.batterton.busbar simulatorExtraBattery -bool false` to disconnect it.
    private let simulator = SimulatedDeltaProSource(
        startingSOC: UserDefaults.standard.object(forKey: "simulatorSOC") as? Double ?? 78,
        scenario: UserDefaults.standard.string(forKey: "simulatorScenario")
            .flatMap(SimulatedDeltaProSource.Scenario.init(rawValue:)) ?? .realistic,
        extraBatteryConnected: UserDefaults.standard.object(forKey: "simulatorExtraBattery") as? Bool ?? true)

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isSimulated: Bool { settings.useSimulatedData || !settings.credentials.isComplete }

    var batteryLevel: BatteryLevel {
        guard let snapshot else { return .normal }
        return .of(snapshot.stateOfCharge, settings: settings.alertSettings)
    }

    /// Something needs attention beyond the battery level: an unavailable battery,
    /// a fault or warning, the bus going quiet, or an EcoFlow error.
    var hasProblem: Bool {
        if isStale || lastError != nil { return true }
        guard let snapshot else { return false }
        return !snapshot.warnings.isEmpty || snapshot.batteries.contains { !$0.isAvailable }
    }

    var isStale: Bool {
        guard let lastUpdate else { return lastError != nil }
        return Date.now.timeIntervalSince(lastUpdate) >= TimeInterval(settings.offlineMinutes * 60)
    }

    /// UNUserNotificationCenter throws if the process isn't an .app bundle (e.g. `swift run`).
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard loop == nil else { return }
        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        restartLoop()
    }

    /// Refresh immediately and restart the polling timer (e.g. after settings change).
    func refreshNow() {
        restartLoop()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(max(10, self.settings.pollInterval)))
            }
        }
    }

    private func refresh() async {
        let source: any PowerSource = isSimulated
            ? simulator
            : EcoFlowDeltaProSource(credentials: settings.credentials)
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await source.snapshot()
            self.snapshot = snapshot
            lastUpdate = .now
            lastError = nil
            notify(alerts.evaluate(snapshot, settings: settings.alertSettings))
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }

        if let alert = alerts.checkStaleness(lastUpdate: lastUpdate, settings: settings.alertSettings) {
            notify([alert])
        }
    }

    private func notify(_ alerts: [Alert]) {
        guard notificationsAvailable else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
