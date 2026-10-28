import Foundation

public struct AlertSettings: Sendable, Equatable {
    public var lowThreshold: Double
    public var criticalThreshold: Double
    public var offlineAfter: TimeInterval
    public var notifyBattery: Bool
    public var notifyOffline: Bool
    public var notifyWarnings: Bool
    public var notifyShorePower: Bool

    public init(lowThreshold: Double = 30, criticalThreshold: Double = 15, offlineAfter: TimeInterval = 600,
                notifyBattery: Bool = true, notifyOffline: Bool = true,
                notifyWarnings: Bool = true, notifyShorePower: Bool = true) {
        self.lowThreshold = lowThreshold
        self.criticalThreshold = criticalThreshold
        self.offlineAfter = offlineAfter
        self.notifyBattery = notifyBattery
        self.notifyOffline = notifyOffline
        self.notifyWarnings = notifyWarnings
        self.notifyShorePower = notifyShorePower
    }
}

public enum BatteryLevel: Int, Sendable, Comparable {
    case normal, low, critical

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func of(_ soc: Double, settings: AlertSettings) -> BatteryLevel {
        if soc <= settings.criticalThreshold { return .critical }
        if soc <= settings.lowThreshold { return .low }
        return .normal
    }
}

public struct Alert: Sendable, Equatable {
    public var title: String
    public var body: String
}

/// Decides when to notify. Each condition fires once when it starts, not on every poll.
public struct AlertEngine: Sendable {
    /// Battery must climb this far above a threshold before it can alert again,
    /// so hovering around 30% doesn't spam notifications.
    static let hysteresis = 3.0

    private var batteryLevel: BatteryLevel = .normal
    private var activeWarnings: Set<String> = []
    private var shorePower: Bool?
    private var isOffline = false

    public init() {}

    public mutating func evaluate(_ snapshot: PowerSnapshot, settings: AlertSettings) -> [Alert] {
        var alerts: [Alert] = []

        if isOffline {
            isOffline = false
            if settings.notifyOffline {
                alerts.append(Alert(title: "Bus is back online", body: "Battery at \(Int(snapshot.stateOfCharge))%."))
            }
        }

        let soc = snapshot.stateOfCharge
        let level = BatteryLevel.of(soc, settings: settings)
        if level > batteryLevel {
            if settings.notifyBattery && snapshot.flow != .charging {
                let title = level == .critical ? "Bus battery critical" : "Bus battery low"
                var body = "Battery at \(Int(soc))%"
                if let minutes = snapshot.minutesToEmpty { body += ", about \(Self.duration(minutes)) left" }
                alerts.append(Alert(title: title, body: body + "."))
            }
            batteryLevel = level
        } else if level < batteryLevel {
            // Only step back down once clearly above the threshold.
            let recovered = BatteryLevel.of(soc - Self.hysteresis, settings: settings)
            batteryLevel = max(level, recovered)
        }

        let warnings = Set(snapshot.warnings)
        if settings.notifyWarnings {
            for warning in warnings.subtracting(activeWarnings).sorted() {
                alerts.append(Alert(title: "Bus power warning", body: warning))
            }
        }
        activeWarnings = warnings

        if let previous = shorePower, previous != snapshot.shorePowerConnected, settings.notifyShorePower {
            alerts.append(snapshot.shorePowerConnected
                ? Alert(title: "Shore power connected", body: "The bus is plugged in.")
                : Alert(title: "Shore power lost", body: "Running on battery at \(Int(soc))%."))
        }
        shorePower = snapshot.shorePowerConnected

        return alerts
    }

    /// Call periodically; returns an alert once when the last good update gets too old.
    public mutating func checkStaleness(lastUpdate: Date?, now: Date = .now, settings: AlertSettings) -> Alert? {
        guard let lastUpdate, !isOffline, now.timeIntervalSince(lastUpdate) >= settings.offlineAfter else { return nil }
        isOffline = true
        guard settings.notifyOffline else { return nil }
        return Alert(title: "Bus is offline",
                     body: "No updates from the Delta Pro for \(Self.duration(Int(now.timeIntervalSince(lastUpdate) / 60))).")
    }

    public static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
