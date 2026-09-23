import AppKit
import Combine

@MainActor
final class SystemUsageMonitor: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    private var task: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    /// One sampler for as long as monitoring stays on. Wake reuses it so the
    /// traffic and energy totals survive sleep; only turning monitoring off
    /// starts a new period.
    private var sampler = SystemUsageSampler()
    private(set) var isEnabled = false

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled else { return }
                    // Sample at once. The same sampler treats the sleep gap as
                    // a hole: it is not billed, and the 60-second trend restarts,
                    // but the totals already measured stay.
                    self.startSampling(keepingHistory: true)
                }
            }
    }

    deinit { task?.cancel() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            sampler = SystemUsageSampler()
            startSampling(keepingHistory: false)
        } else {
            task?.cancel()
            task = nil
            snapshots = []
        }
    }

    private func startSampling(keepingHistory: Bool) {
        task?.cancel()
        if !keepingHistory {
            // The first pass has no baseline yet. Say so without pretending the
            // meters failed. Wake leaves the last real cells in place.
            snapshots = SystemUsageReading().snapshots.map {
                var snapshot = $0
                snapshot.status = .unsupported(L10n.t("Sampling…"))
                return snapshot
            }
        }
        let sampler = self.sampler
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled, self != nil {
                let reading = await sampler.sample()
                guard !Task.isCancelled else { return }
                self?.snapshots = reading.snapshots
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
}

extension SystemUsageReading {
    var snapshots: [ProviderSnapshot] {
        var snapshots = [percentSnapshot(id: "cpu", name: "CPU", glyph: .systemCPU, fraction: cpu,
                         label: "All cores", unavailable: "Sampling CPU…"),
         capacitySnapshot(id: "memory", name: "RAM", glyph: .systemRAM, capacity: memory,
                          label: "Physical memory"),
         percentSnapshot(id: "gpu", name: "GPU", glyph: .systemGPU, fraction: gpu,
                         label: "Busiest GPU", unavailable: "GPU utilization is unavailable on this Mac."),
         capacitySnapshot(id: "disk", name: "DISK", glyph: .systemDisk, capacity: disk,
                          label: "Home volume"),
         networkSnapshot, batterySnapshot, powerSnapshot]
        snapshots[0].cpuCores = cpuCores
        for index in snapshots.indices where snapshots[index].hasReading {
            let id = String(snapshots[index].id.dropFirst("system-".count))
            var extra: [LimitWindow] = []
            func row(_ id: String, _ label: String.LocalizationValue, _ value: String) {
                extra.append(LimitWindow(id: id, label: L10n.t(label), detail: value))
            }
            if let recent = recent[id] {
                let value = id == "power"
                    ? "\(Self.watts(recent.average)) / \(Self.watts(recent.peak))"
                    : "\(Percent.text(for: recent.average))% / \(Percent.text(for: recent.peak))%"
                row("recent", "Last 60s avg / peak", value)
            }
            switch id {
            case "cpu":
                if let cpuUser, let cpuSystem {
                    row("cpu-split", "User / System", "\(Percent.text(for: cpuUser))% / \(Percent.text(for: cpuSystem))%")
                }
                if let logicalCores { row("cores", "Logical cores", String(logicalCores)) }
                if let thermalState {
                    let state: String
                    switch thermalState {
                    case .nominal: state = L10n.t("Normal")
                    case .fair: state = L10n.t("Warm")
                    case .serious: state = L10n.t("High")
                    case .critical: state = L10n.t("Critical")
                    @unknown default: state = L10n.t("Unknown")
                    }
                    row("thermal", "Thermal pressure", state)
                }
                if let uptime { row("uptime", "Uptime", Self.measuredDuration(uptime)) }
            case "gpu":
                if let gpuDetails {
                    if let renderer = gpuDetails.renderer { row("renderer", "Renderer activity", "\(Percent.text(for: renderer))%") }
                    if let tiler = gpuDetails.tiler { row("tiler", "Tiler activity", "\(Percent.text(for: tiler))%") }
                    if let memory = gpuDetails.memoryUsed { row("gpu-memory", "GPU memory in use", Self.bytes(memory)) }
                }
                row("gpu-core-note", "Per-core load", L10n.t("Unavailable"))
            case "memory":
                if let memoryDetails {
                    row("wired", "Wired memory", Self.bytes(memoryDetails.wired))
                    row("compressed", "Compressed memory", Self.bytes(memoryDetails.compressed))
                    if let swap = memoryDetails.swapUsed { row("swap", "Swap used", Self.bytes(swap)) }
                }
            case "disk":
                if let disk { row("free", "Free space", Self.bytes(disk.total - min(disk.used, disk.total))) }
                if let diskAvailableForFiles { row("available", "Available for files", Self.bytes(diskAvailableForFiles)) }
            case "network":
                if let link = networkLink {
                    row("connection", "Primary connection", [link.title, link.interface].compactMap { $0 }.joined(separator: " · "))
                    if let rssi = link.rssi { row("signal", "Wi-Fi signal", "\(rssi) dBm") }
                    if let rssi = link.rssi, let noise = link.noise { row("snr", "Signal / noise margin", "\(rssi - noise) dB") }
                    if let rate = link.transmitMbps {
                        row("link-rate", "Wi-Fi link rate",
                            String(format: "%.0f Mbps", locale: Locale(identifier: "en_US_POSIX"), rate))
                    }
                }
                if let networkTotals {
                    row("received-total", "Received while monitoring", Self.bytes(networkTotals.received))
                    row("sent-total", "Sent while monitoring", Self.bytes(networkTotals.sent))
                    row("measured-time", "Measured for", Self.measuredDuration(networkMeasuredSeconds))
                }
                if !networkInterfaces.isEmpty { row("interfaces", "Interfaces", networkInterfaces.joined(separator: ", ")) }
            case "battery":
                if let battery = power?.battery {
                    if battery.state == .charging || battery.state == .batteryPower {
                        let label: String.LocalizationValue = battery.state == .charging ? "Until full (est.)" : "Time remaining (est.)"
                        row("remaining-time", label, battery.minutesRemaining.map {
                            UsageFormat.duration(seconds: Double($0) * 60)
                        } ?? L10n.t("Calculating…"))
                    }
                    if let health = battery.health { row("health", "Battery condition", health) }
                    if let lowPower = battery.lowPowerMode { row("low-power", "Low Power Mode", lowPower ? L10n.t("On") : L10n.t("Off")) }
                }
            case "power":
                if let energy {
                    row("energy", "Measured energy (est.)",
                        String(format: "%.2f Wh", locale: Locale(identifier: "en_US_POSIX"), energy.wattHours))
                    row("measured-time", "Measured for", Self.measuredDuration(energy.measuredSeconds))
                }
            default: break
            }
            snapshots[index].windows += extra
        }
        return snapshots
    }

    private func percentSnapshot(id: String, name: String, glyph: ProviderGlyph, fraction: Double?,
                                 label: String.LocalizationValue, unavailable: String.LocalizationValue) -> ProviderSnapshot {
        ProviderSnapshot(id: "system-\(id)", displayName: name, glyph: glyph, fidelity: .official,
                         status: fraction == nil ? .unsupported(L10n.t(unavailable)) : .ok,
                         windows: fraction.map { [LimitWindow(id: id, label: L10n.t(label), usedFraction: $0,
                                                             detail: L10n.t("\(Percent.text(for: $0))% active"))] } ?? [],
                         kind: .system)
    }

    private func capacitySnapshot(id: String, name: String, glyph: ProviderGlyph,
                                  capacity: Capacity?, label: String.LocalizationValue) -> ProviderSnapshot {
        var snapshot = percentSnapshot(id: id, name: name, glyph: glyph, fraction: capacity?.fraction,
                                       label: label, unavailable: "No reading")
        if let capacity {
            snapshot.windows = [LimitWindow(id: id, label: L10n.t(label), usedFraction: capacity.fraction,
                                            detail: "\(Self.bytes(capacity.used)) / \(Self.bytes(capacity.total))")]
        }
        return snapshot
    }

    private var networkSnapshot: ProviderSnapshot {
        let windows: [LimitWindow]
        if let network {
            let fraction = networkLink?.ringFraction
            let label = networkLink?.kind == .wifi ? L10n.t("Wi-Fi signal (relative)")
                : networkLink?.kind == .wired ? L10n.t("Wired connection")
                : networkLink?.kind == .disconnected ? L10n.t("Connection") : L10n.t("Total traffic")
            let detail = networkLink?.kind == .wifi
                ? networkLink?.rssi.map { "\($0) dBm" } ?? L10n.t("Signal unavailable")
                : networkLink?.kind == .wired ? L10n.t("Ethernet connected")
                : networkLink?.kind == .disconnected ? L10n.t("No primary connection") : Self.rate(network.received + network.sent)
            windows = [
                LimitWindow(id: "network", label: label, usedFraction: fraction,
                            usedText: Self.rate(network.received + network.sent, compact: true),
                            detail: detail,
                            bandOverride: fraction.map { UsageBand.band(for: 1 - $0, watchLimit: 0.5, criticalLimit: 0.8) },
                            prefersUsedText: true),
                LimitWindow(id: "download", label: L10n.t("Download"), detail: Self.rate(network.received)),
                LimitWindow(id: "upload", label: L10n.t("Upload"), detail: Self.rate(network.sent))
            ]
        } else { windows = [] }
        return ProviderSnapshot(id: "system-network", displayName: "NET", glyph: .systemNetwork,
                                fidelity: .official,
                                status: network == nil ? .unsupported(L10n.t("Sampling network…")) : .ok,
                                windows: windows, kind: .system, plan: L10n.t("Ethernet / Wi-Fi"))
    }

    private static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private static func bytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max).nextDown)), countStyle: .memory)
    }

    static func measuredDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let seconds = Int(min(seconds, Double(Int.max).nextDown))
        if seconds >= 86_400 { return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private var batterySnapshot: ProviderSnapshot {
        guard let battery = power?.battery else {
            return ProviderSnapshot(id: "system-battery", displayName: "BAT", glyph: .systemBattery,
                                    fidelity: .official, status: .unsupported(L10n.t("Battery information is unavailable on this Mac.")),
                                    windows: [], kind: .system)
        }
        let state: String
        switch battery.state {
        case .charging: state = L10n.t("Charging")
        case .charged: state = L10n.t("Fully charged")
        case .externalPower: state = L10n.t("External power · Not charging")
        case .batteryPower: state = L10n.t("On battery")
        }
        let percent = "\(Percent.text(for: battery.fraction))%"
        let window = LimitWindow(id: "battery", label: L10n.t("Battery remaining"),
                                 usedFraction: battery.fraction,
                                 usedText: percent + (battery.state == .charging ? " ⚡︎" : ""),
                                 detail: L10n.t("\(percent) remaining"),
                                 bandOverride: UsageBand.band(for: 1 - battery.fraction,
                                                              watchLimit: 0.8, criticalLimit: 0.9),
                                 prefersUsedText: true)
        return ProviderSnapshot(id: "system-battery", displayName: "BAT", glyph: .systemBattery,
                                fidelity: .official, status: .ok, windows: [window], kind: .system, plan: state)
    }

    private var powerSnapshot: ProviderSnapshot {
        guard let telemetry = power?.telemetry else {
            return ProviderSnapshot(id: "system-power", displayName: "PWR", glyph: .systemPower,
                                    fidelity: .official, status: .unsupported(L10n.t("Power consumption is unavailable. Waiting for a supported sensor reading.")),
                                    windows: [], kind: .system)
        }
        var windows = [LimitWindow(id: "power", label: L10n.t("System consumption"),
                                   usedText: Self.watts(telemetry.systemWatts), detail: Self.watts(telemetry.systemWatts))]
        if let adapter = telemetry.adapterWatts {
            windows.append(LimitWindow(id: "adapter", label: L10n.t("Adapter input"), detail: Self.watts(adapter)))
        }
        if let battery = telemetry.batteryWatts {
            windows.append(LimitWindow(id: "battery-flow", label: battery < 0 ? L10n.t("Battery discharge") : L10n.t("Into battery"),
                                       detail: Self.watts(abs(battery))))
        }
        return ProviderSnapshot(id: "system-power", displayName: "PWR", glyph: .systemPower,
                                fidelity: .official, status: .ok, windows: windows, kind: .system,
                                plan: L10n.t("Sensor updates periodically"))
    }

    private static func watts(_ value: Double) -> String {
        String(format: "%.1fW", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func rate(_ bytes: Double, compact: Bool = false) -> String {
        let units = compact ? ["B/s", "K/s", "M/s", "G/s", "T/s"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytes.isFinite ? max(0, bytes) : 0
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: unit == 0 || value >= 100 ? "%.0f%@" : "%.1f%@",
                      locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}
