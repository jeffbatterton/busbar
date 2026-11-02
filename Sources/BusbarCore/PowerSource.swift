import Foundation

/// An output that can be switched on and off remotely.
public enum PowerOutput: Sendable, Hashable {
    case ac, dc12V
}

/// Anything that can produce a snapshot of the electrical system.
public protocol PowerSource: Sendable {
    func snapshot() async throws -> PowerSnapshot
    func setOutput(_ output: PowerOutput, on: Bool) async throws
}

public struct EcoFlowDeltaProSource: PowerSource {
    public let client: EcoFlowClient

    public init(credentials: EcoFlowCredentials) {
        client = EcoFlowClient(credentials: credentials)
    }

    public func snapshot() async throws -> PowerSnapshot {
        PowerSnapshot(deltaPro: try await client.allQuotas())
    }

    public func setOutput(_ output: PowerOutput, on: Bool) async throws {
        // Delta Pro command ids: 66 is AC discharge, 81 the 12V car port.
        let id = switch output {
        case .ac: 66
        case .dc12V: 81
        }
        try await client.setQuota(["id": id, "enabled": on ? 1 : 0])
    }
}

/// Fake Delta Pro data for running the app without API access. It emits raw quota
/// values with the real field names, so the parsing path is exercised too.
public actor SimulatedDeltaProSource: PowerSource {
    public enum Scenario: String, Sendable {
        /// Solar follows the real time of day.
        case realistic
        /// Driving: the 800W alternator charger is running, no solar.
        case charging
        /// No input at all.
        case discharging
    }

    private var soc: Double
    private let scenario: Scenario
    private let extraBatteryConnected: Bool
    private var lastTick: Date?
    private var acOn = true
    private var dc12VOn = true
    /// Speeds up battery drain/charge so changes are visible while testing.
    private let timeScale: Double
    // Delta Pro (3.6 kWh) + one extra battery (3.6 kWh).
    private var capacityWh: Double { extraBatteryConnected ? 7200 : 3600 }

    public init(startingSOC: Double = 78, scenario: Scenario = .realistic,
                extraBatteryConnected: Bool = true, timeScale: Double = 10) {
        soc = startingSOC
        self.scenario = scenario
        self.extraBatteryConnected = extraBatteryConnected
        self.timeScale = timeScale
    }

    public func snapshot() async throws -> PowerSnapshot {
        PowerSnapshot(deltaPro: quotas())
    }

    public func setOutput(_ output: PowerOutput, on: Bool) async throws {
        switch output {
        case .ac: acOn = on
        case .dc12V: dc12VOn = on
        }
    }

    func quotas(now: Date = .now) -> Quotas {
        let hour = Double(Calendar.current.component(.hour, from: now))
            + Double(Calendar.current.component(.minute, from: now)) / 60

        // Solar: a bell curve between 6:00 and 20:00 peaking around 1.2 kW.
        let daylight = max(0, sin((hour - 6) / 14 * .pi))
        let solar = scenario == .realistic ? Int(1200 * daylight * Double.random(in: 0.85...1.0)) : 0
        let alternator = scenario == .charging ? 780 + Int.random(in: -20...15) : 0

        // Loads: fridge and electronics always on, plus an occasional big AC load.
        let acOut = acOn ? 140 + Int.random(in: -20...30) + (Int.random(in: 0..<10) == 0 ? 900 : 0) : 0
        let dc12V = dc12VOn ? 45 + Int.random(in: 0...15) : 0
        let wattsOut = acOut + dc12V
        // A full battery stops charging. Decide once, before the level updates below.
        let isFull = soc >= 100
        let solarIn = isFull ? 0 : solar
        let wattsIn = isFull ? 0 : solarIn + alternator

        if let lastTick {
            let hours = now.timeIntervalSince(lastTick) / 3600 * timeScale
            soc = min(100, max(0, soc + Double(wattsIn - wattsOut) * hours / capacityWh * 100))
        }
        lastTick = now

        let net = Double(wattsIn - wattsOut)
        // The packs balance through the main: the extra feeds it while discharging,
        // and it tops up the extra while charging. The Delta Pro counts the extra's
        // output in its total input.
        let toExtra = extraBatteryConnected ? Int(net / 2) : 0
        let toFull = net > 0 ? Int((100 - soc) / 100 * capacityWh / net * 60) : 5999
        let toEmpty = net < 0 ? Int(soc / 100 * capacityWh / -net * 60) : 5999

        var quotas = Quotas([
            "ems.f32LcdShowSoc": soc,
            "pd.soc": soc.rounded(),
            "bmsMaster.f32ShowSoc": extraBatteryConnected ? min(100, soc + 1.5) : soc,
            "bmsMaster.temp": 27,
            "ems.bms0Online": 3,
            "ems.bms1Online": extraBatteryConnected ? 3 : 0,
            "pd.wattsInSum": Double(wattsIn + max(0, -toExtra)),
            "pd.wattsOutSum": Double(wattsOut),
            "mppt.inWatts": Double(solarIn * 10),   // tenths of a watt
            "mppt.xt60ChgType": 1,
            "inv.inputWatts": 0,
            "inv.acInVol": 0,
            "inv.outputWatts": Double(acOut),
            "inv.cfgAcEnabled": acOn ? 1 : 0,
            "mppt.carState": dc12VOn ? 1 : 0,
            "pd.carWatts": Double(dc12V),
            "ems.chgRemainTime": Double(toFull),
            "ems.dsgRemainTime": Double(toEmpty),
        ])
        if extraBatteryConnected {
            quotas.merge(Quotas(["bmsSlave1.f32ShowSoc": max(0, soc - 1.5), "bmsSlave1.temp": 26,
                                 "bmsSlave1.outputWatts": Double(max(0, -toExtra)),
                                 "bmsSlave1.inputWatts": Double(max(0, toExtra))]))
        }
        return quotas
    }
}
