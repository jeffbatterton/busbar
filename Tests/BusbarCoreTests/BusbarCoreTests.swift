import Foundation
import Testing
@testable import BusbarCore

@Suite struct QuotaParsingTests {
    // Shape taken from EcoFlow's documented quota/all response: numbers arrive as strings.
    let quotas = Quotas(json: [
        "ems.f32LcdShowSoc": "64.5",
        "pd.wattsInSum": "900",
        "pd.wattsOutSum": "300",
        "mppt.inWatts": "400",
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
        let switchedOn = PowerSnapshot(deltaPro: Quotas(["inv.cfgAcEnabled": 1, "pd.carState": 0]))
        #expect(switchedOn.acOutputOn && !switchedOn.dc12VOutputOn)
        let drawing = PowerSnapshot(deltaPro: Quotas(["mppt.dcdc12vWatts": 40]))
        #expect(!drawing.acOutputOn && drawing.dc12VOutputOn)
    }
}

@Suite struct SigningTests {
    @Test func signatureMatchesReferenceImplementation() {
        // Reference: hmac.new(b"secret", b"sn=DCABZ123&accessKey=AK&nonce=345164&timestamp=1681872798000", sha256)
        let sign = EcoFlowClient.signature(params: ["sn": "DCABZ123"], accessKey: "AK", secretKey: "secret",
                                           nonce: "345164", timestamp: "1681872798000")
        #expect(sign == "e7de08da82c96795a52fef3ca276328f80f0fd31c24a4e8e754d85abe45bd592")
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
