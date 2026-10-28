import Foundation

/// A point-in-time view of the bus electrical system, independent of where the data came from.
public struct PowerSnapshot: Sendable, Equatable {
    public enum Flow: Sendable, Equatable {
        case charging, discharging, idle
    }

    public struct Battery: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// nil when the pack is connected but not reporting a percentage.
        public var stateOfCharge: Double?
        /// Degrees Celsius, as reported by EcoFlow.
        public var temperature: Double?
    }

    /// Combined state of charge across all packs, 0–100.
    public var stateOfCharge: Double
    public var wattsIn: Int
    public var wattsOut: Int

    public var solarWatts: Int
    public var acInWatts: Int
    /// Input not accounted for by solar or AC. On this bus that's the alternator charger,
    /// which plugs into the extra battery port and isn't reported separately.
    public var otherInWatts: Int

    public var acOutWatts: Int
    public var dc12VOutWatts: Int

    public var shorePowerConnected: Bool
    public var minutesToFull: Int?
    public var minutesToEmpty: Int?
    public var batteries: [Battery]
    public var warnings: [String]
    public var timestamp: Date

    public var flow: Flow {
        let net = wattsIn - wattsOut
        if net > 5 { return .charging }
        if net < -5 { return .discharging }
        return .idle
    }

    public var netWatts: Int { wattsIn - wattsOut }
}

extension PowerSnapshot {
    /// Interprets Delta Pro quotas. Field names come from EcoFlow's Delta Pro
    /// developer docs; `bmsSlave1.*` is undocumented but reported by real units.
    public init(deltaPro q: Quotas, at timestamp: Date = .now) {
        stateOfCharge = q["ems.f32LcdShowSoc"] ?? q["ems.lcdShowSoc"] ?? q["pd.soc"] ?? 0
        wattsIn = q.int("pd.wattsInSum") ?? 0
        wattsOut = q.int("pd.wattsOutSum") ?? 0

        // The XT60 port is solar unless it's detected as a DC adapter.
        solarWatts = q.int("mppt.xt60ChgType") == 2 ? 0 : (q.int("mppt.inWatts") ?? 0)
        acInWatts = q.int("inv.inputWatts") ?? 0
        otherInWatts = max(0, wattsIn - solarWatts - acInWatts)

        acOutWatts = q.int("inv.outputWatts") ?? 0
        dc12VOutWatts = (q.int("pd.carWatts") ?? 0) + (q.int("mppt.dcdc12vWatts") ?? 0)

        // inv.acInVol is in millivolts; anything over ~80 V means shore power is present.
        shorePowerConnected = (q["inv.acInVol"] ?? 0) > 80_000

        // EcoFlow reports 5999 (or larger) when it can't estimate; treat that as unknown.
        func plausibleMinutes(_ key: String) -> Int? {
            guard let m = q.int(key), m > 0, m < 5999 else { return nil }
            return m
        }
        minutesToFull = plausibleMinutes("ems.chgRemainTime")
        minutesToEmpty = plausibleMinutes("ems.dsgRemainTime")

        var batteries = [Battery(name: "Main",
                                 stateOfCharge: q["bmsMaster.f32ShowSoc"] ?? q["bmsMaster.soc"],
                                 temperature: q["bmsMaster.temp"])]
        let extraOnline = (q.int("ems.bms1Online") ?? 0) & 1 == 1 || (q.int("pd.ext4p8Port") ?? 0) != 0
        if extraOnline || q["bmsSlave1.soc"] != nil {
            batteries.append(Battery(name: "Extra",
                                     stateOfCharge: q["bmsSlave1.f32ShowSoc"] ?? q["bmsSlave1.soc"],
                                     temperature: q["bmsSlave1.temp"]))
        }
        self.batteries = batteries

        var warnings: [String] = []
        let warningState = q.int("ems.bmsWarningState") ?? 0
        if q.int("pd.iconOverloadState") == 1 || warningState & 0b100 != 0 { warnings.append("Overload") }
        if q.int("pd.iconHiTempState") == 1 || warningState & 0b001 != 0 { warnings.append("High temperature") }
        if q.int("pd.iconLowTempState") == 1 || warningState & 0b010 != 0 { warnings.append("Low temperature") }
        for (key, label) in [("pd.errCode", "System"), ("inv.errCode", "Inverter"),
                             ("mppt.faultCode", "Solar/DC"), ("bmsMaster.errCode", "Battery"),
                             ("bmsMaster.bmsFault", "Battery permanent")] {
            if let code = q.int(key), code != 0 { warnings.append("\(label) fault (\(code))") }
        }
        self.warnings = warnings
        self.timestamp = timestamp
    }
}
