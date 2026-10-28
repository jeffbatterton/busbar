import BusbarCore
import Foundation
import Observation
import ServiceManagement

/// User preferences. Secrets live in the Keychain; everything else in UserDefaults.
@MainActor @Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var accessKey: String { didSet { Keychain.set(accessKey, for: "accessKey") } }
    var secretKey: String { didSet { Keychain.set(secretKey, for: "secretKey") } }
    var serialNumber: String { didSet { defaults.set(serialNumber, forKey: "serialNumber") } }
    var useSimulatedData: Bool { didSet { defaults.set(useSimulatedData, forKey: "useSimulatedData") } }

    var lowThreshold: Double {
        didSet {
            defaults.set(lowThreshold, forKey: "lowThreshold")
            if criticalThreshold >= lowThreshold { criticalThreshold = lowThreshold - 1 }
        }
    }
    var criticalThreshold: Double {
        didSet {
            defaults.set(criticalThreshold, forKey: "criticalThreshold")
            if lowThreshold <= criticalThreshold { lowThreshold = criticalThreshold + 1 }
        }
    }
    var pollInterval: Int { didSet { defaults.set(pollInterval, forKey: "pollInterval") } }
    var offlineMinutes: Int { didSet { defaults.set(offlineMinutes, forKey: "offlineMinutes") } }
    var notifyBattery: Bool { didSet { defaults.set(notifyBattery, forKey: "notifyBattery") } }
    var notifyOffline: Bool { didSet { defaults.set(notifyOffline, forKey: "notifyOffline") } }
    var notifyWarnings: Bool { didSet { defaults.set(notifyWarnings, forKey: "notifyWarnings") } }
    var notifyShorePower: Bool { didSet { defaults.set(notifyShorePower, forKey: "notifyShorePower") } }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        defaults.register(defaults: [
            "useSimulatedData": true,
            "lowThreshold": 30.0,
            "criticalThreshold": 15.0,
            "pollInterval": 60,
            "offlineMinutes": 10,
            "notifyBattery": true,
            "notifyOffline": true,
            "notifyWarnings": true,
            "notifyShorePower": true,
        ])
        accessKey = Keychain.string(for: "accessKey") ?? ""
        secretKey = Keychain.string(for: "secretKey") ?? ""
        serialNumber = defaults.string(forKey: "serialNumber") ?? ""
        useSimulatedData = defaults.bool(forKey: "useSimulatedData")
        lowThreshold = defaults.double(forKey: "lowThreshold")
        criticalThreshold = defaults.double(forKey: "criticalThreshold")
        pollInterval = defaults.integer(forKey: "pollInterval")
        offlineMinutes = defaults.integer(forKey: "offlineMinutes")
        notifyBattery = defaults.bool(forKey: "notifyBattery")
        notifyOffline = defaults.bool(forKey: "notifyOffline")
        notifyWarnings = defaults.bool(forKey: "notifyWarnings")
        notifyShorePower = defaults.bool(forKey: "notifyShorePower")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var credentials: EcoFlowCredentials {
        EcoFlowCredentials(accessKey: accessKey.trimmingCharacters(in: .whitespaces),
                           secretKey: secretKey.trimmingCharacters(in: .whitespaces),
                           serialNumber: serialNumber.trimmingCharacters(in: .whitespaces))
    }

    var alertSettings: AlertSettings {
        AlertSettings(lowThreshold: lowThreshold, criticalThreshold: criticalThreshold,
                      offlineAfter: TimeInterval(offlineMinutes * 60),
                      notifyBattery: notifyBattery, notifyOffline: notifyOffline,
                      notifyWarnings: notifyWarnings, notifyShorePower: notifyShorePower)
    }
}
