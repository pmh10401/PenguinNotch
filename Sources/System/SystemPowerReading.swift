import Foundation
import IOKit
import IOKit.ps

struct SystemPowerReading: Equatable, Sendable {
    struct Battery: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case charging, charged, externalPower, batteryPower
        }
        let fraction: Double
        let state: State
        var minutesRemaining: Int?
        var health: String?
        var lowPowerMode: Bool?
        var onExternalPower: Bool { state != .batteryPower }

        static func decode(_ source: [String: Any]) -> Self? {
            guard source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  source[kIOPSIsPresentKey] as? Bool == true,
                  let current = source[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = source[kIOPSMaxCapacityKey] as? NSNumber,
                  current.doubleValue.isFinite, maximum.doubleValue.isFinite,
                  maximum.doubleValue > 0, (0...maximum.doubleValue).contains(current.doubleValue),
                  let charging = source[kIOPSIsChargingKey] as? Bool,
                  let powerSource = source[kIOPSPowerSourceStateKey] as? String else { return nil }
            let state: State
            switch powerSource {
            case kIOPSACPowerValue:
                state = charging ? .charging
                    : (source[kIOPSIsChargedKey] as? Bool == true ? .charged : .externalPower)
            case kIOPSBatteryPowerValue:
                guard !charging else { return nil }
                state = .batteryPower
            default: return nil
            }
            let timeKey = state == .charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (source[timeKey] as? NSNumber).flatMap { number -> Int? in
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      (1...10_080).contains(number.doubleValue), number.doubleValue.rounded() == number.doubleValue
                else { return nil }
                return number.intValue
            }
            let health: String?
            switch source[kIOPSBatteryHealthConditionKey] as? String {
            case kIOPSCheckBatteryValue, kIOPSPermanentFailureValue: health = L10n.t("Service recommended")
            default:
                switch source[kIOPSBatteryHealthKey] as? String {
                case kIOPSGoodValue: health = L10n.t("Good")
                case kIOPSFairValue: health = L10n.t("Reduced capacity")
                case kIOPSPoorValue: health = L10n.t("Service recommended")
                default: health = nil
                }
            }
            return .init(fraction: current.doubleValue / maximum.doubleValue, state: state,
                         minutesRemaining: state == .charging || state == .batteryPower ? minutes : nil,
                         health: health)
        }
    }

    struct Telemetry: Equatable, Sendable {
        let systemWatts: Double
        let adapterWatts: Double?
        /// Positive enters the battery; negative leaves it.
        let batteryWatts: Double?

        static func decode(_ values: [String: Any], state: Battery.State) -> Self? {
            func watts(_ key: String, signed: Bool = false) -> Double? {
                guard let value = values[key] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                // IORegistry can bridge a negative 64-bit battery value as unsigned.
                let milliwatts = value.int64Value
                guard (signed ? -2_000_000...2_000_000 : 0...2_000_000).contains(milliwatts) else { return nil }
                return Double(milliwatts) / 1000
            }
            guard let system = watts("SystemLoad") else { return nil }
            let input = watts("SystemPowerIn")
            let battery = watts("BatteryPower", signed: true)
            // Drop contradictory cached readings while the charger or charging state changes.
            if state == .batteryPower {
                if let input, input > 0.5 { return nil }
                if let battery, battery > 0.5 { return nil }
            } else if let input, input == 0, system > 0.5 { return nil }
            if state == .charging, let battery, battery < -0.5 { return nil }
            if let input, let battery, abs(input - battery - system) > max(1, system * 0.05) { return nil }
            return .init(systemWatts: system, adapterWatts: state == .batteryPower ? nil : input,
                         batteryWatts: battery)
        }
    }

    let battery: Battery?
    let telemetry: Telemetry?

    static func read() -> Self {
        var battery = readBattery()
        battery?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .init(battery: battery, telemetry: nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Public battery state and the driver's cached telemetry can disagree briefly on unplug.
        guard let battery, let external = property("ExternalConnected") as? Bool,
              external == battery.onExternalPower,
              let values = property("PowerTelemetryData") as? [String: Any] else {
            return .init(battery: battery, telemetry: nil)
        }
        // ponytail: these driver fields are undocumented and update at the hardware's cadence.
        // Unsupported drivers stay unavailable; add a verified sensor source for other Macs.
        return .init(battery: battery, telemetry: Telemetry.decode(values, state: battery.state))
    }

    private static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let battery = Battery.decode(description) else { continue }
            return battery
        }
        return nil
    }
}
