import IOKit.ps
import XCTest
@testable import PenguinNotch

final class SystemPowerTests: XCTestCase {
    func testBatteryStatesAndPowerUnitsStayDistinct() throws {
        var source: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: false, kIOPSIsChargedKey: false, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        var battery = try XCTUnwrap(SystemPowerReading.Battery.decode(source))
        XCTAssertEqual(battery.fraction, 0.8)
        XCTAssertEqual(battery.state, .externalPower, "AC attached at 80% is not necessarily charging or full")
        source[kIOPSTimeToFullChargeKey] = 45
        source[kIOPSTimeToEmptyKey] = 180
        source[kIOPSBatteryHealthKey] = kIOPSGoodValue
        XCTAssertNil(SystemPowerReading.Battery.decode(source)?.minutesRemaining, "Paused charging has no completion estimate")
        source[kIOPSIsChargingKey] = true
        XCTAssertEqual(SystemPowerReading.Battery.decode(source)?.state, .charging)
        XCTAssertEqual(SystemPowerReading.Battery.decode(source)?.minutesRemaining, 45)
        XCTAssertEqual(SystemPowerReading.Battery.decode(source)?.health, "Good")
        for invalid in [-1, 0, 100_000] {
            source[kIOPSTimeToFullChargeKey] = invalid
            XCTAssertNil(SystemPowerReading.Battery.decode(source)?.minutesRemaining)
        }
        source[kIOPSIsChargingKey] = false
        source[kIOPSIsChargedKey] = true
        XCTAssertEqual(SystemPowerReading.Battery.decode(source)?.state, .charged)
        source[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        source[kIOPSCurrentCapacityKey] = 0
        battery = try XCTUnwrap(SystemPowerReading.Battery.decode(source))
        XCTAssertEqual(battery.state, .batteryPower)
        XCTAssertEqual(battery.fraction, 0)
        XCTAssertEqual(battery.minutesRemaining, 180)
        let empty = SystemUsageReading(power: .init(battery: battery, telemetry: nil)).snapshots[5]
        XCTAssertEqual(empty.headlineText, "0%")
        XCTAssertEqual(empty.bandOverride, .exhausted)
        source[kIOPSMaxCapacityKey] = 0
        XCTAssertNil(SystemPowerReading.Battery.decode(source))
        source[kIOPSMaxCapacityKey] = 100
        source[kIOPSTypeKey] = kIOPSUPSType
        XCTAssertNil(SystemPowerReading.Battery.decode(source), "An external UPS is not the Mac's battery")

        let values: [String: Any] = ["SystemLoad": 25_000, "SystemPowerIn": 40_000, "BatteryPower": 15_000]
        let charging = try XCTUnwrap(SystemPowerReading.Telemetry.decode(values, state: .charging))
        XCTAssertEqual(charging.systemWatts, 25)
        XCTAssertEqual(charging.adapterWatts, 40)
        XCTAssertEqual(charging.batteryWatts, 15)
        let discharge = try XCTUnwrap(SystemPowerReading.Telemetry.decode(
            ["SystemLoad": 25_000, "SystemPowerIn": 0,
             "BatteryPower": NSNumber(value: UInt64(bitPattern: -25_000))], state: .batteryPower))
        XCTAssertNil(discharge.adapterWatts, "Do not reuse a cached charger input after unplugging")
        XCTAssertEqual(discharge.batteryWatts, -25)
        let powerCell = SystemUsageReading(power: .init(battery: battery, telemetry: discharge)).snapshots[6]
        XCTAssertEqual(powerCell.windows.last?.label, "Battery discharge")
        XCTAssertEqual(powerCell.windows.last?.detail, "25.0W")
        XCTAssertEqual(SystemPowerReading.Telemetry.decode(["SystemLoad": 0], state: .charged)?.systemWatts, 0)
        XCTAssertNil(SystemPowerReading.Telemetry.decode(values, state: .batteryPower), "Reject old AC telemetry after unplugging")
        XCTAssertNil(SystemPowerReading.Telemetry.decode(
            ["SystemLoad": 25_000, "SystemPowerIn": 40_000, "BatteryPower": -25_000], state: .charging))
        let invalidReadings: [[String: Any]] = [[:], ["Watts": 140], ["SystemPowerIn": 40_000],
            ["SystemLoad": -1], ["SystemLoad": Double.nan], ["SystemLoad": true],
            ["SystemLoad": 25_000, "SystemPowerIn": 40_000, "BatteryPower": 5_000]]
        for invalid in invalidReadings {
            XCTAssertNil(SystemPowerReading.Telemetry.decode(invalid, state: .charging))
        }
    }
}
