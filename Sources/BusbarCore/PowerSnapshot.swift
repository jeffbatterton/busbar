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
        /// False when the pack is reported but offline or disconnected.
        public var isAvailable: Bool
    }

    /// Combined state of charge across all packs, 0–100.
    public var stateOfCharge: Double
    /// Power coming in from outside the system: solar, AC and other input added up.
    /// Excludes the extra battery feeding the main pack, which is only a transfer.
    public var wattsIn: Int
    public var wattsOut: Int

    public var solarWatts: Int
    public var acInWatts: Int
    /// Input not accounted for by solar or AC. On this bus that's the alternator charger,
    /// which plugs into the extra battery port and isn't reported separately.
    public var otherInWatts: Int
    /// Power moving between the packs: positive while the extra battery feeds the main,
    /// negative while the main charges the extra. Zero when under 10 W, so balancing
    /// trickles don't flicker on and off.
    public var packTransferWatts: Int

    public var acOutWatts: Int
    public var dc12VOutWatts: Int
    /// Whether each output is switched on, regardless of whether anything is drawing power.
    public var acOutputOn: Bool
    public var dc12VOutputOn: Bool

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

    public func isOn(_ output: PowerOutput) -> Bool {
        switch output {
        case .ac: acOutputOn
        case .dc12V: dc12VOutputOn
        }
    }

    /// Switches an output in place. Switching off also drops its draw from the totals,
    /// since a switched-off output can't be using power.
    public mutating func setOn(_ output: PowerOutput, _ on: Bool) {
        switch output {
        case .ac: acOutputOn = on
        case .dc12V: dc12VOutputOn = on
        }
        guard !on else { return }
        switch output {
        case .ac: wattsOut -= acOutWatts; acOutWatts = 0
        case .dc12V: wattsOut -= dc12VOutWatts; dc12VOutWatts = 0
        }
    }

    /// Puts an output's switch and draw back as they were in `earlier`.
    public mutating func restore(_ output: PowerOutput, from earlier: PowerSnapshot) {
        switch output {
        case .ac:
            wattsOut += earlier.acOutWatts - acOutWatts
            (acOutputOn, acOutWatts) = (earlier.acOutputOn, earlier.acOutWatts)
        case .dc12V:
            wattsOut += earlier.dc12VOutWatts - dc12VOutWatts
            (dc12VOutputOn, dc12VOutWatts) = (earlier.dc12VOutputOn, earlier.dc12VOutWatts)
        }
    }
}

extension PowerSnapshot {
    /// Interprets Delta Pro quotas. Field names come from EcoFlow's Delta Pro
    /// developer docs; `bmsSlave1.*` is undocumented but reported by real units.
    public init(deltaPro q: Quotas, at timestamp: Date = .now) {
        stateOfCharge = q["ems.f32LcdShowSoc"] ?? q["ems.lcdShowSoc"] ?? q["pd.soc"] ?? 0
        wattsIn = q.int("pd.wattsInSum") ?? 0
        wattsOut = q.int("pd.wattsOutSum") ?? 0

        // The mppt.*Watts fields are in tenths of a watt; the rest are whole watts.
        func mpptWatts(_ key: String) -> Int? { q[key].map { Int(($0 / 10).rounded()) } }

        // The XT60 port is solar unless it's detected as a DC adapter.
        solarWatts = q.int("mppt.xt60ChgType") == 2 ? 0 : (mpptWatts("mppt.inWatts") ?? 0)
        acInWatts = q.int("inv.inputWatts") ?? 0
        // The extra battery discharging into the Delta Pro is counted in wattsInSum.
        let extraBatteryWatts = q.int("bmsSlave1.outputWatts") ?? 0
        let transfer = extraBatteryWatts - (q.int("bmsSlave1.inputWatts") ?? 0)
        packTransferWatts = abs(transfer) < 10 ? 0 : transfer
        let unexplained = wattsIn - solarWatts - acInWatts - extraBatteryWatts
        // Separately measured readings rarely match, and the extra battery's lags a little;
        // under 25 W left over is noise (the alternator charger runs in the hundreds).
        otherInWatts = unexplained < 25 ? 0 : unexplained
        wattsIn = solarWatts + acInWatts + otherInWatts

        acOutWatts = q.int("inv.outputWatts") ?? 0
        dc12VOutWatts = (q.int("pd.carWatts") ?? 0) + (mpptWatts("mppt.dcdc12vWatts") ?? 0)
        // Prefer the switch states; fall back to "drawing power" if they aren't reported.
        acOutputOn = q.int("inv.cfgAcEnabled") == 1 || acOutWatts > 0
        // The 12V car port's switch is mppt.carState; pd.carState stays 0 on real units.
        dc12VOutputOn = q.int("mppt.carState").map { $0 == 1 } ?? (dc12VOutWatts > 0)

        // inv.acInVol is in millivolts; anything over ~80 V means shore power is present.
        shorePowerConnected = (q["inv.acInVol"] ?? 0) > 80_000

        // EcoFlow reports 5999 (or larger) when it can't estimate; treat that as unknown.
        func plausibleMinutes(_ key: String) -> Int? {
            guard let m = q.int(key), m > 0, m < 5999 else { return nil }
            return m
        }
        minutesToFull = plausibleMinutes("ems.chgRemainTime")
        minutesToEmpty = plausibleMinutes("ems.dsgRemainTime")

        // ems.bmsNOnline bit 0 is the pack's hardware-online signal.
        var batteries = [Battery(name: "Main",
                                 stateOfCharge: q["bmsMaster.f32ShowSoc"] ?? q["bmsMaster.soc"],
                                 temperature: q["bmsMaster.temp"],
                                 isAvailable: q.int("ems.bms0Online").map { $0 & 1 == 1 } ?? true)]
        let extraSOC = q["bmsSlave1.f32ShowSoc"] ?? q["bmsSlave1.soc"]
        // Listed whenever the Delta Pro reports on the extra battery port, so a
        // disconnected pack shows as unavailable rather than disappearing.
        if q["ems.bms1Online"] != nil || q["pd.ext4p8Port"] != nil || extraSOC != nil {
            let online = (q.int("ems.bms1Online") ?? 0) & 1 == 1 || (q.int("pd.ext4p8Port") ?? 0) != 0 || extraSOC != nil
            batteries.append(Battery(name: "Extra",
                                     stateOfCharge: online ? extraSOC : nil,
                                     temperature: online ? q["bmsSlave1.temp"] : nil,
                                     isAvailable: online))
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
