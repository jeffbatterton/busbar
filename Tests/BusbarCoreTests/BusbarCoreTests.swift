import Foundation
import Testing
@testable import BusbarCore

@Suite struct QuotaParsingTests {
    // Shape taken from EcoFlow's documented quota/all response: numbers arrive as strings.
    let quotas = Quotas(json: [
        "ems.f32LcdShowSoc": "64.5",
        "pd.wattsInSum": "900",
        "pd.wattsOutSum": "300",
        "mppt.inWatts": "4000",   // tenths of a watt
        "mppt.xt60ChgType": "1",
        "inv.inputWatts": "0",
        "inv.acInVol": "0",
        "inv.outputWatts": "220",
        "pd.carWatts": "50",
        "pd.typec1Watts": "20",
        "ems.chgRemainTime": "185",
        "ems.dsgRemainTime": "5999",
        "ems.bms1Online": "3",
        "bmsMaster.f32ShowSoc": 66.0,
        "pd.iconOverloadState": "1",
        "inv.errCode": "0",
        "pd.model": "not-a-number",
    ])

    @Test func parsesCoreValues() {
        let s = PowerSnapshot(deltaPro: quotas)
        #expect(s.stateOfCharge == 64.5)
        #expect(s.flow == .charging)
        #expect(s.solarWatts == 400)
        #expect(s.otherInWatts == 500)   // alternator charger shows up as unexplained input
        #expect(s.dc12VOutWatts == 50)
        #expect(s.minutesToFull == 185)
        #expect(s.minutesToEmpty == nil)
        #expect(!s.shorePowerConnected)
    }

    @Test func readsChargeLimits() {
        let s = PowerSnapshot(deltaPro: Quotas(["ems.minDsgSoc": 10, "ems.maxChargeSoc": 90]))
        #expect(s.dischargeLimit == 10)
        #expect(s.chargeLimit == 90)
        let unset = PowerSnapshot(deltaPro: Quotas([:]))
        #expect(unset.dischargeLimit == 0)
        #expect(unset.chargeLimit == 100)
        let crossed = PowerSnapshot(deltaPro: Quotas(["ems.minDsgSoc": 60, "ems.maxChargeSoc": 50]))
        #expect(crossed.dischargeLimit == 0)
        #expect(crossed.chargeLimit == 100)
    }

    @Test func extraBatteryDischargeIsNotOtherInput() {
        // Real reading: 427 W in, 393 W solar, extra battery discharging 37 W, engine off.
        let s = PowerSnapshot(deltaPro: Quotas(["pd.wattsInSum": 427, "mppt.inWatts": 3930,
                                                "bmsSlave1.outputWatts": 37]))
        #expect(s.otherInWatts == 0)
        let noise = PowerSnapshot(deltaPro: Quotas(["pd.wattsInSum": 570, "mppt.inWatts": 5680]))
        #expect(noise.otherInWatts == 0)
    }

    @Test func extraBatteryDischargeIsNotInput() {
        // Nothing plugged in; the extra battery is topping up the main pack.
        let s = PowerSnapshot(deltaPro: Quotas(["pd.wattsInSum": 208, "pd.wattsOutSum": 407,
                                                "bmsSlave1.outputWatts": 208]))
        #expect(s.wattsIn == 0)
        #expect(s.flow == .discharging)
    }

    @Test func packTransferDirection() {
        let feeding = PowerSnapshot(deltaPro: Quotas(["bmsSlave1.outputWatts": 208]))
        #expect(feeding.packTransferWatts == 208)
        let charging = PowerSnapshot(deltaPro: Quotas(["bmsSlave1.inputWatts": 186]))
        #expect(charging.packTransferWatts == -186)
        let trickle = PowerSnapshot(deltaPro: Quotas(["bmsSlave1.outputWatts": 6]))
        #expect(trickle.packTransferWatts == 0)
    }

    @Test func detectsExtraBatteryAndWarnings() {
        let s = PowerSnapshot(deltaPro: quotas)
        #expect(s.batteries.map(\.name) == ["Main", "Extra"])
        #expect(s.batteries[1].stateOfCharge == nil)
        #expect(s.batteries.allSatisfy { $0.isAvailable })
        #expect(s.warnings == ["Overload"])
    }
}

extension QuotaParsingTests {
    @Test func disconnectedExtraBatteryIsUnavailable() {
        let s = PowerSnapshot(deltaPro: Quotas(["ems.bms0Online": 3, "ems.bms1Online": 0]))
        #expect(s.batteries.map(\.name) == ["Main", "Extra"])
        #expect(s.batteries.map(\.isAvailable) == [true, false])
    }

    @Test func outputsOnBySwitchOrDraw() {
        let switchedOn = PowerSnapshot(deltaPro: Quotas(["inv.cfgAcEnabled": 1, "mppt.carState": 0]))
        #expect(switchedOn.acOutputOn && !switchedOn.dc12VOutputOn)
        // A switched-off port stays grey even with stray draw, and pd.* switches are ignored.
        let off = PowerSnapshot(deltaPro: Quotas(["mppt.carState": 0, "pd.carState": 1, "pd.dcOutState": 1,
                                                  "mppt.dcdc12vWatts": 23]))
        #expect(!off.dc12VOutputOn)
        #expect(PowerSnapshot(deltaPro: Quotas(["mppt.carState": 1])).dc12VOutputOn)
        let drawing = PowerSnapshot(deltaPro: Quotas(["mppt.dcdc12vWatts": 400]))
        #expect(!drawing.acOutputOn && drawing.dc12VOutputOn)
    }
}

extension QuotaParsingTests {
    @Test func switchingOffDropsDrawAndRestoreBringsItBack() {
        let before = PowerSnapshot(deltaPro: Quotas(["inv.cfgAcEnabled": 1, "inv.outputWatts": 300,
                                                     "pd.carWatts": 40, "pd.wattsOutSum": 340]))
        var s = before
        s.setOn(.ac, false)
        #expect(!s.acOutputOn && s.acOutWatts == 0 && s.wattsOut == 40)
        s.restore(.ac, from: before)
        #expect(s == before)
    }
}

@Suite struct SigningTests {
    @Test func signatureMatchesReferenceImplementation() {
        // Reference: hmac.new(b"secret", b"sn=DCABZ123&accessKey=AK&nonce=345164&timestamp=1681872798000", sha256)
        let sign = EcoFlowClient.signature(params: ["sn": "DCABZ123"], accessKey: "AK", secretKey: "secret",
                                           nonce: "345164", timestamp: "1681872798000")
        #expect(sign == "e7de08da82c96795a52fef3ca276328f80f0fd31c24a4e8e754d85abe45bd592")
    }

    @Test func setCommandSignsFlattenedParamsInKeyOrder() {
        // Reference: hmac.new(b"secret", b"operateType=TCP&params.enabled=0&params.id=81&sn=DCABZ123&accessKey=AK&nonce=345164&timestamp=1681872798000", sha256)
        let sign = EcoFlowClient.signature(params: ["sn": "DCABZ123", "operateType": "TCP",
                                                    "params.id": "81", "params.enabled": "0"],
                                           accessKey: "AK", secretKey: "secret",
                                           nonce: "345164", timestamp: "1681872798000")
        #expect(sign == "bcf456d73671f0b391ec8aa52e17c1ba2a22bf8ddf5fea493e39963c95aae2e2")
    }
}

@Suite struct AlertEngineTests {
    let settings = AlertSettings()

    func snapshot(soc: Double, watts: Int = -200, shore: Bool = false) -> PowerSnapshot {
        var q = Quotas(["ems.f32LcdShowSoc": soc, "pd.wattsOutSum": Double(max(0, -watts)),
                        "pd.wattsInSum": Double(max(0, watts))])
        if shore { q.merge(Quotas(["inv.acInVol": 120_000])) }
        return PowerSnapshot(deltaPro: q)
    }

    @Test func lowAlertFiresOnceWithHysteresis() {
        var engine = AlertEngine()
        #expect(engine.evaluate(snapshot(soc: 50), settings: settings).isEmpty)
        #expect(engine.evaluate(snapshot(soc: 29), settings: settings).map(\.title) == ["Bus battery low"])
        #expect(engine.evaluate(snapshot(soc: 28), settings: settings).isEmpty)
        #expect(engine.evaluate(snapshot(soc: 31), settings: settings).isEmpty)  // within hysteresis
        #expect(engine.evaluate(snapshot(soc: 29), settings: settings).isEmpty)
        #expect(engine.evaluate(snapshot(soc: 14), settings: settings).map(\.title) == ["Bus battery critical"])
        _ = engine.evaluate(snapshot(soc: 40), settings: settings)
        #expect(engine.evaluate(snapshot(soc: 29), settings: settings).map(\.title) == ["Bus battery low"])
    }

    @Test func shorePowerChanges() {
        var engine = AlertEngine()
        #expect(engine.evaluate(snapshot(soc: 80, shore: true), settings: settings).isEmpty)
        #expect(engine.evaluate(snapshot(soc: 80), settings: settings).map(\.title) == ["Shore power lost"])
    }

    @Test func offlineFiresOnceThenRecovers() {
        var engine = AlertEngine()
        let last = Date(timeIntervalSince1970: 0)
        #expect(engine.checkStaleness(lastUpdate: last, now: last.addingTimeInterval(300), settings: settings) == nil)
        #expect(engine.checkStaleness(lastUpdate: last, now: last.addingTimeInterval(700), settings: settings)?.title == "Bus is offline")
        #expect(engine.checkStaleness(lastUpdate: last, now: last.addingTimeInterval(900), settings: settings) == nil)
        #expect(engine.evaluate(snapshot(soc: 70), settings: settings).map(\.title) == ["Bus is back online"])
    }
}

@Suite struct ChargeHistoryTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// One reading a minute from `start`, at a steady charge.
    func readings(from start: Date, minutes: Int, soc: Double = 50, wattsIn: Int = 0) -> [ChargeReading] {
        (0..<minutes).map {
            ChargeReading(time: start.addingTimeInterval(Double($0) * 60), stateOfCharge: soc,
                          wattsIn: wattsIn, wattsOut: 200)
        }
    }

    @Test func windowsAreCalendarDaysAndMondayWeeks() {
        // Sunday Nov 1 2026 is also the day US daylight saving ends, so it's 25 hours long.
        let sunday = HistoryRange.today.window(containing: date(1, 15), calendar: calendar)
        #expect(sunday.start == date(1, 0))
        #expect(sunday.duration == 25 * 3600)
        let week = HistoryRange.week.window(containing: date(2, 9), calendar: calendar)
        #expect(week.start == date(2, 0))  // Monday
        #expect(week.end == date(9, 0))
        #expect(HistoryRange.week.window(containing: date(8, 23), calendar: calendar).start == date(2, 0))  // Sunday
    }

    @Test func liveCentersOnNow() {
        let live = HistoryRange.live.window(containing: date(2, 9), calendar: calendar)
        #expect(live.start == date(2, 6))
        #expect(live.end == date(2, 12))
    }

    @Test func splitsRunsAtGapsOverFiveMinutes() {
        let first = readings(from: date(3, 1), minutes: 10)
        let second = readings(from: first.last!.time.addingTimeInterval(5 * 60), minutes: 3)
        let third = readings(from: second.last!.time.addingTimeInterval(6 * 60), minutes: 3)
        let runs = ChargeHistory.runs(first + second + third)
        #expect(runs.map(\.count) == [13, 3])
    }

    @Test func outagesAreGapsOverFifteenMinutesAndTheTimeSinceTheLastReading() {
        let first = readings(from: date(5, 3), minutes: 10)
        let second = readings(from: first.last!.time.addingTimeInterval(15 * 60), minutes: 10)
        let third = readings(from: date(5, 10, 15), minutes: 10)
        let all = first + second + third
        #expect(ChargeHistory.outages(all, now: third.last!.time.addingTimeInterval(60))
            == [DateInterval(start: second.last!.time, end: date(5, 10, 15))])
        // Quiet for over 15 minutes up to now: offline since the last reading.
        #expect(ChargeHistory.outages(all, now: date(5, 11)).last
            == DateInterval(start: third.last!.time, end: date(5, 11)))
    }

    @Test func smoothingAveragesBucketsAndEndsOnTheLastReading() {
        var run = readings(from: date(3, 1), minutes: 25)
        for index in run.indices { run[index].stateOfCharge = Double(index) }
        let points = ChargeHistory.smoothed(run, bucket: 10 * 60)
        #expect(points.count == 3)
        #expect(points[0].stateOfCharge == 4.5)   // minutes 0–9
        #expect(points[0].time == date(3, 1, 4).addingTimeInterval(30))
        #expect(points[2] == ChargePoint(time: run.last!.time, stateOfCharge: 24))
    }

    @Test func historyAppendsOnlyNewerReadingsAndTrims() {
        var history = ChargeHistory()
        #expect(history.nextFetch(from: date(2, 0)) == date(2, 0))
        history.append(readings(from: date(2, 10), minutes: 3))
        history.append(readings(from: date(2, 10, 1), minutes: 4))  // overlaps by two
        #expect(history.readings.count == 5)
        #expect(history.nextFetch(from: date(2, 0)) > date(2, 10, 4))
        history.trim(before: date(2, 10, 2))
        #expect(history.readings.first?.time == date(2, 10, 2))
    }

    @Test func parsesLoggerResponse() throws {
        let json = #"{"simulated":false,"readings":[[1793733822553,46.8,250,394],[1793733882553,46.8,243,397]]}"#
        let readings = try HistoryClient.parse(Data(json.utf8))
        #expect(readings.count == 2)
        #expect(readings[0] == ChargeReading(time: Date(timeIntervalSince1970: 1793733822.553),
                                             stateOfCharge: 46.8, wattsIn: 250, wattsOut: 394))
        #expect(throws: HistoryError.self) { try HistoryClient.parse(Data(#"{"error":"Unauthorized"}"#.utf8)) }
    }
}
