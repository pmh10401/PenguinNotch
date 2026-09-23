import CoreWLAN
import Foundation
import SystemConfiguration

struct SystemNetworkLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case wifi, wired, other, disconnected }
    let kind: Kind
    var interface: String?
    var rssi: Int?
    var noise: Int?
    var transmitMbps: Double?

    static let wifiSettingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!

    var ringFraction: Double? {
        switch kind {
        case .wired: return 1
        case .disconnected: return 0
        case .other: return nil
        case .wifi: return Self.signalFraction(rssi: rssi)
        }
    }

    static func signalFraction(rssi: Int?) -> Double? {
        guard let rssi, (-120 ... -1).contains(rssi) else { return nil }
        // ponytail: -90…-50 dBm is a relative visual scale, never a bandwidth percentage.
        // Keep the measured dBm in the card; tune these endpoints if radios need a different scale.
        return min(1, max(0, Double(rssi + 90) / 40))
    }

    var title: String {
        switch kind {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .other: return L10n.t("Other connection")
        case .disconnected: return L10n.t("No primary connection")
        }
    }

    static func read() -> Self {
        guard let store = SCDynamicStoreCreate(nil, "CodenotchNetwork" as CFString, nil, nil) else {
            return .init(kind: .other)
        }
        let primary = ["IPv4", "IPv6"].compactMap { family -> String? in
            let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
            return state?["PrimaryInterface"] as? String
        }
        guard !primary.isEmpty else { return .init(kind: .disconnected) }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for name in primary {
            guard let interface = interfaces.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == name })
            else { continue }
            guard let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            if type == (kSCNetworkInterfaceTypeEthernet as String) {
                return .init(kind: .wired, interface: name)
            }
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                return wirelessLink(interface: name)
            }
        }
        // VPN and unrecognized routes do not imply Ethernet or a fabricated Wi-Fi signal.
        return .init(kind: .other, interface: primary.first)
    }

    /// The radio named `name`, even when it is not the primary route.
    /// A powered-off radio stays Wi-Fi with no invented signal.
    static func wirelessLink(interface name: String) -> Self {
        guard let wifi = CWWiFiClient.shared().interface(withName: name), wifi.powerOn() else {
            return .init(kind: .wifi, interface: name)
        }
        let rssi = wifi.rssiValue(), noise = wifi.noiseMeasurement(), rate = wifi.transmitRate()
        return .init(kind: .wifi, interface: name,
                     rssi: (-120 ... -1).contains(rssi) ? rssi : nil,
                     noise: (-120 ... -1).contains(noise) ? noise : nil,
                     transmitMbps: rate.isFinite && rate > 0 ? rate : nil)
    }
}
