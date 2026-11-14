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
    /// EcoFlow says the Delta Pro itself is offline, rather than something going wrong.
    private(set) var isDeviceOffline = false
    private(set) var isRefreshing = false
    /// This week's readings from the history logger; empty when it isn't set up.
    private(set) var history = ChargeHistory()
    /// Set when the logger can't be reached and there's nothing to show.
    private(set) var historyError: String?
    /// The thresholds the logger last accepted, so they're only sent when they change.
    private var savedThresholds: [Double]?
    /// Outputs with a switch command in flight.
    private(set) var switchingOutputs: Set<PowerOutput> = []
    /// States just switched to, shown until the device reports them (it lags a few seconds).
    private var expectedOutputs: [PowerOutput: (on: Bool, until: Date)] = [:]
    /// Limits with a set command in flight.
    private(set) var settingLimits: Set<ChargeLimit> = []
    /// Limits just set, shown until the device reports them.
    private var expectedLimits: [ChargeLimit: (percent: Double, until: Date)] = [:]

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
        alerts.warningsNotified = UserDefaults.standard.dictionary(forKey: "warningsNotified") as? [String: Date] ?? [:]
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

    private var source: any PowerSource {
        isSimulated ? simulator : EcoFlowDeltaProSource(credentials: settings.credentials)
    }

    /// Switches an output on or off, showing the new state before the command is sent
    /// and putting the old one back if it fails.
    func setOutput(_ output: PowerOutput, on: Bool) {
        guard !switchingOutputs.contains(output), let before = snapshot else { return }
        switchingOutputs.insert(output)
        expectedOutputs[output] = (on, .now.addingTimeInterval(20))
        snapshot?.setOn(output, on)
        Task {
            defer { switchingOutputs.remove(output) }
            do {
                try await source.setOutput(output, on: on)
                lastError = nil
                try? await Task.sleep(for: .seconds(3))
                refreshNow()
            } catch {
                expectedOutputs[output] = nil
                snapshot?.restore(output, from: before)
                lastError = "Couldn't switch \(on ? "on" : "off"): \(error.localizedDescription)"
            }
        }
    }

    /// Sets a charge limit, showing it before the command is sent and putting the old one
    /// back if it fails.
    func setLimit(_ limit: ChargeLimit, to percent: Int) {
        guard let before = snapshot?.value(of: limit), Double(percent) != before else { return }
        settingLimits.insert(limit)
        expectedLimits[limit] = (Double(percent), .now.addingTimeInterval(20))
        snapshot?.setLimit(limit, to: Double(percent))
        Task {
            defer { settingLimits.remove(limit) }
            do {
                try await source.setLimit(limit, to: percent)
                lastError = nil
                try? await Task.sleep(for: .seconds(3))
                refreshNow()
            } catch {
                expectedLimits[limit] = nil
                snapshot?.setLimit(limit, to: before)
                lastError = "Couldn't set the \(limit == .charge ? "charge" : "discharge") limit: \(error.localizedDescription)"
            }
        }
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

    /// Forgets fetched history and refetches, e.g. after the logger settings change.
    func resetHistory() {
        history = ChargeHistory()
        historyError = nil
        savedThresholds = nil
        refreshNow()
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
        let source = source
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var snapshot = try await source.snapshot()
            for (output, expected) in expectedOutputs {
                if snapshot.isOn(output) == expected.on || expected.until < .now {
                    expectedOutputs[output] = nil
                } else {
                    snapshot.setOn(output, expected.on)
                }
            }
            for (limit, expected) in expectedLimits {
                if snapshot.value(of: limit) == expected.percent || expected.until < .now {
                    expectedLimits[limit] = nil
                } else {
                    snapshot.setLimit(limit, to: expected.percent)
                }
            }
            self.snapshot = snapshot
            lastUpdate = .now
            lastError = nil
            isDeviceOffline = false
            notify(alerts.evaluate(snapshot, settings: settings.alertSettings))
            UserDefaults.standard.set(alerts.warningsNotified, forKey: "warningsNotified")
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
            isDeviceOffline = if case EcoFlowError.offline = error { true } else { false }
        }

        if let alert = alerts.checkStaleness(lastUpdate: lastUpdate, settings: settings.alertSettings) {
            notify([alert])
        }
        await refreshHistory()
    }

    /// Fetches only the readings since the last one, keeping enough for every range: this
    /// calendar week's, and early on a Monday the last few hours of the week before.
    private func refreshHistory() async {
        guard let client = settings.historyClient else {
            history = ChargeHistory()
            historyError = nil
            return
        }
        let start = HistoryRange.allCases.map { $0.window(containing: .now).start }.min()!
        history.trim(before: start)
        do {
            history.append(try await client.readings(since: history.nextFetch(from: start)))
            historyError = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            historyError = error.localizedDescription
        }
        // Shares the thresholds with the web app; a failure is retried next time.
        let thresholds = [settings.lowThreshold, settings.criticalThreshold]
        if thresholds != savedThresholds,
           (try? await client.saveThresholds(low: thresholds[0], critical: thresholds[1])) != nil {
            savedThresholds = thresholds
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
