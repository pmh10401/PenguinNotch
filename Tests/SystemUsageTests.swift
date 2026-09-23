import Combine
import SwiftUI
import XCTest
@testable import Codenotch

final class SystemUsageTests: XCTestCase {
    func testNetworkRingReflectsPrimaryLinkAndKeepsTrafficLabel() {
        var reading = Self.reading
        reading.networkLink = .init(kind: .wifi, interface: "en0", rssi: -65, noise: -94, transmitMbps: 360)
        var net = reading.snapshots[4]
        XCTAssertEqual(net.ringFraction, 0.625)
        XCTAssertEqual(net.headlineText, "1.5M/s", "A signal arc must not replace the traffic label")
        XCTAssertEqual(net.windows.first?.detail, "-65 dBm")
        XCTAssertEqual(net.windows.first { $0.id == "link-rate" }?.detail, "360 Mbps")
        XCTAssertEqual(SystemNetworkLink.signalFraction(rssi: -100), 0)
        XCTAssertEqual(SystemNetworkLink.signalFraction(rssi: -40), 1)
        XCTAssertNil(SystemNetworkLink.signalFraction(rssi: 0), "CoreWLAN uses zero for unavailable RSSI")
        XCTAssertNil(SystemNetworkLink.signalFraction(rssi: -999))
        reading.networkLink = .init(kind: .wired, interface: "en7")
        net = reading.snapshots[4]
        XCTAssertEqual(net.ringFraction, 1)
        XCTAssertEqual(net.bandOverride, .ample, "Full means connected, not overloaded")
        XCTAssertEqual(net.headlineText, "1.5M/s")
        reading.networkLink = .init(kind: .disconnected)
        XCTAssertEqual(reading.snapshots[4].ringFraction, 0)
        reading.networkLink = .init(kind: .other, interface: "utun3")
        XCTAssertNil(reading.snapshots[4].ringFraction, "Unknown/VPN routes must not masquerade as Ethernet")
        XCTAssertEqual(SystemNetworkLink.wifiSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.wifi-settings-extension")
    }

    func testCPUDeltasIncludeNiceAndHandleCounterWrap() throws {
        let previous = SystemCPUTicks(user: UInt32.max - 4, system: 10, idle: 100, nice: 0)
        let current = SystemCPUTicks(user: 5, system: 20, idle: 160, nice: 20)
        XCTAssertEqual(try XCTUnwrap(current.fraction(since: previous)), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(current.fractions(since: previous)).user, 0.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(current.fractions(since: previous)).system, 0.1, accuracy: 0.0001)
        XCTAssertNil(current.fraction(since: current))
    }

    func testCoreLoadsKeepIdentityAndRebaselineAfterGapsOrTopologyChanges() throws {
        let previous = [SystemCPUTicks(user: UInt32.max - 4, system: 10, idle: 100, nice: 0),
                        SystemCPUTicks(user: 10, system: 10, idle: 100, nice: 0)]
        let current = [SystemCPUTicks(user: 5, system: 20, idle: 160, nice: 20),
                       SystemCPUTicks(user: 10, system: 10, idle: 200, nice: 0)]
        let loads = SystemCPUTicks.coreLoads(current: current, previous: previous, elapsed: 1)
        XCTAssertEqual(loads.map(\.id), [0, 1])
        XCTAssertEqual(try XCTUnwrap(loads[0].fraction), 0.4, accuracy: 0.0001)
        XCTAssertEqual(loads[1].fraction, 0, "A measured idle core is zero, not unavailable")
        for elapsed: Double? in [nil, 0, -1, 11, .infinity, .nan] {
            XCTAssertTrue(SystemCPUTicks.coreLoads(current: current, previous: previous, elapsed: elapsed)
                .allSatisfy { $0.fraction == nil })
        }
        for baseline: [SystemCPUTicks]? in [nil, [], [previous[0]], current] {
            XCTAssertTrue(SystemCPUTicks.coreLoads(current: current, previous: baseline, elapsed: 1)
                .allSatisfy { $0.fraction == nil })
        }
        var reading = Self.reading
        reading.cpuCores = loads
        XCTAssertEqual(reading.snapshots[0].cpuCores, loads)
        XCTAssertEqual(reading.snapshots[0].ringFraction, 0, "Core peaks must not replace the aggregate ring")
        XCTAssertTrue(reading.snapshots.dropFirst().allSatisfy { $0.cpuCores.isEmpty })
    }

    func testGPUDetailsValidateOptionalCountersWithoutInventingCoreLoads() throws {
        let gpu = try XCTUnwrap(SystemUsageSampler.gpuReading(statistics: [
            "Device Utilization %": 93, "Renderer Utilization %": 82,
            "Tiler Utilization %": 41, "In use system memory": 1_600_000_000]))
        XCTAssertEqual(gpu.fraction, 0.93)
        XCTAssertEqual(gpu.details.renderer, 0.82)
        XCTAssertEqual(gpu.details.tiler, 0.41)
        XCTAssertEqual(gpu.details.memoryUsed, 1_600_000_000)
        var reading = Self.reading
        reading.gpuDetails = gpu.details
        let snapshot = reading.snapshots[2]
        XCTAssertEqual(snapshot.windows.first { $0.id == "renderer" }?.detail, "82%")
        XCTAssertEqual(snapshot.windows.first { $0.id == "tiler" }?.detail, "41%")
        XCTAssertTrue(snapshot.cpuCores.isEmpty)
        let invalid = try XCTUnwrap(SystemUsageSampler.gpuReading(statistics: [
            "Device Utilization %": 0, "Renderer Utilization %": Double.nan,
            "Tiler Utilization %": 101, "In use system memory": -1]))
        XCTAssertNil(invalid.details.renderer)
        XCTAssertNil(invalid.details.tiler)
        XCTAssertNil(invalid.details.memoryUsed)
        XCTAssertNil(SystemUsageSampler.gpuReading(statistics: ["Device Utilization %": -1]))
    }

    func testHoverHistoryMeasuresOnlyObservedIntervalsAndBoundsRecentValues() throws {
        var history = SystemUsageHistory()
        var first = Self.reading
        history.enrich(&first, at: 100)
        XCTAssertNil(first.energy)
        XCTAssertNil(first.networkTotals)
        XCTAssertTrue(first.recent.isEmpty)
        var next = Self.reading
        next.cpu = 0.5
        history.enrich(&next, at: 102)
        XCTAssertEqual(try XCTUnwrap(next.energy).wattHours, 50.0 / 3600, accuracy: 0.000001)
        XCTAssertEqual(next.energy?.measuredSeconds, 2)
        XCTAssertEqual(next.networkTotals?.received, 2_400_000)
        XCTAssertEqual(next.networkTotals?.sent, 600_000)
        XCTAssertEqual(next.recent["cpu"]?.average, 0.25)
        XCTAssertEqual(next.recent["cpu"]?.peak, 0.5)
        XCTAssertEqual(SystemUsageReading.measuredDuration(2), "2s")
        XCTAssertEqual(SystemUsageReading.measuredDuration(61), "1m 1s")
        XCTAssertEqual(SystemUsageReading.measuredDuration(90_061), "1d 1h")

        var afterGap = Self.reading
        history.enrich(&afterGap, at: 200)
        XCTAssertTrue(afterGap.recent.isEmpty, "A sleep or stalled sampler must discard the old trend")
        XCTAssertEqual(afterGap.energy, next.energy, "Do not integrate watts across a sampling gap")
        XCTAssertEqual(afterGap.networkTotals, next.networkTotals)
        var unavailable = SystemUsageReading()
        history.enrich(&unavailable, at: 201)
        var restored = Self.reading
        history.enrich(&restored, at: 202)
        XCTAssertEqual(restored.energy, next.energy, "Missing power readings break the integration interval")
        for time in 203...264 {
            var reading = Self.reading
            reading.cpu = 1
            history.enrich(&reading, at: Double(time))
            restored = reading
        }
        XCTAssertEqual(restored.recent["cpu"]?.average, 1)
        XCTAssertEqual(restored.recent["cpu"]?.peak, 1)
        XCTAssertNotNil(restored.snapshots[6].windows.first { $0.id == "energy" })
        XCTAssertNotNil(restored.snapshots[4].windows.first { $0.id == "received-total" })
    }

    func testNetworkUsesElapsedTimeAndRebaselinesChangedInterfaces() throws {
        let old = ["en0": SystemNetworkBytes(received: 5_000_000_000, sent: 100)]
        let new = ["en0": SystemNetworkBytes(received: 5_000_004_000, sent: 700),
                   "en7": SystemNetworkBytes(received: 900_000_000, sent: 900_000_000)]
        let rate = try XCTUnwrap(SystemNetworkBytes.rate(current: new, previous: old, elapsed: 2))
        XCTAssertEqual(rate.received, 2000)
        XCTAssertEqual(rate.sent, 300)
        XCTAssertNil(SystemNetworkBytes.rate(current: old, previous: new, elapsed: 1))
        XCTAssertNil(SystemNetworkBytes.rate(current: new, previous: old, elapsed: 60))
        XCTAssertNil(SystemNetworkBytes.rate(current: new, previous: old, elapsed: 0))
        XCTAssertNil(SystemNetworkBytes.rate(current: new, previous: [:], elapsed: 1))
        XCTAssertEqual(SystemNetworkBytes.rate(current: [:], previous: [:], elapsed: 1)?.received, 0)
    }

    func testNetworkParserRejectsTruncatedAndZeroLengthMessages() {
        XCTAssertNil(SystemUsageSampler.networkCounters(in: Data([0, 0, 5, 18])))
        XCTAssertNil(SystemUsageSampler.networkCounters(in: Data([255, 0, 5, 18])))
        XCTAssertNil(SystemUsageSampler.networkCounters(in: Data([4, 0, 5, 18])))
        XCTAssertNil(SystemUsageSampler.networkCounters(in: Data([1])))
        XCTAssertTrue(SystemUsageSampler.networkCounters(in: Data())?.isEmpty == true)
    }

    func testLiveSamplingIsBoundedAndStartsWithoutRates() async throws {
        let sampler = SystemUsageSampler()
        let first = await sampler.sample()
        XCTAssertNil(first.cpu)
        XCTAssertNil(first.network)
        XCTAssertFalse(first.cpuCores.isEmpty)
        XCTAssertTrue(first.cpuCores.allSatisfy { $0.fraction == nil })
        try await Task.sleep(for: .milliseconds(1100))
        let next = await sampler.sample()
        XCTAssertTrue((0...1).contains(try XCTUnwrap(next.cpu)))
        let memory = try XCTUnwrap(next.memory)
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertLessThanOrEqual(try XCTUnwrap(next.memoryDetails).wired, memory.total)
        XCTAssertLessThanOrEqual(try XCTUnwrap(next.memoryDetails).compressed, memory.total)
        XCTAssertNotNil(next.cpuUser)
        XCTAssertNotNil(next.cpuSystem)
        XCTAssertFalse(next.cpuCores.isEmpty)
        XCTAssertEqual(next.cpuCores.count, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue(next.cpuCores.allSatisfy { $0.fraction.map { (0...1).contains($0) } == true })
        print("LIVE_CPU_CORES count=\(next.cpuCores.count) fractions=\(next.cpuCores.map { $0.fraction ?? -1 })")
        XCTAssertNotNil(next.thermalState)
        let disk = try XCTUnwrap(next.disk)
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertLessThanOrEqual(disk.used, disk.total)
        if let available = next.diskAvailableForFiles { XCTAssertLessThanOrEqual(available, disk.total) }
        if let gpu = next.gpu { XCTAssertTrue((0...1).contains(gpu)) }
        print("LIVE_GPU \(next.gpu.map { String($0) } ?? "unavailable") renderer=\(String(describing: next.gpuDetails?.renderer))")
        if let power = next.power?.telemetry {
            print("LIVE_POWER system=\(power.systemWatts)W adapter=\(String(describing: power.adapterWatts)) battery=\(String(describing: power.batteryWatts))")
        } else {
            print("LIVE_POWER unavailable")
        }
        if let network = next.network {
            XCTAssertGreaterThanOrEqual(network.received, 0)
            XCTAssertGreaterThanOrEqual(network.sent, 0)
        }
        XCTAssertNotNil(next.networkLink)
        print("LIVE_NETWORK_LINK \(next.networkLink?.title ?? "unknown") \(next.networkLink?.interface ?? "none") arc=\(String(describing: next.networkLink?.ringFraction))")
        let wifi = SystemNetworkLink.wirelessLink(interface: "en0")
        print("LIVE_WIFI iface=\(wifi.interface ?? "none") rssi=\(String(describing: wifi.rssi)) noise=\(String(describing: wifi.noise)) mbps=\(String(describing: wifi.transmitMbps))")
        if let rssi = wifi.rssi { XCTAssertTrue((-120 ... -1).contains(rssi)) }
        if let noise = wifi.noise { XCTAssertTrue((-120 ... -1).contains(noise)) }
        if let rate = wifi.transmitMbps { XCTAssertGreaterThan(rate, 0) }
        if let battery = next.power?.battery { XCTAssertTrue((0...1).contains(battery.fraction)) }
        if let power = next.power?.telemetry { XCTAssertGreaterThanOrEqual(power.systemWatts, 0) }
    }

    func testSystemCellsKeepZeroUnavailableAndUnitsDistinct() {
        let reading = Self.reading
        let cells = reading.snapshots
        XCTAssertEqual(cells.map(\.displayName), ["CPU", "RAM", "GPU", "DISK", "NET", "BAT", "PWR"])
        XCTAssertEqual(Set(cells.map(\.id)).count, 7)
        XCTAssertTrue(cells.allSatisfy { $0.kind == .system })
        XCTAssertEqual(cells[0].headlineText, "0%")
        XCTAssertEqual(cells[1].usedFraction, 0.5)
        XCTAssertEqual(cells[4].headlineText, "1.5M/s")
        XCTAssertNil(cells[4].ringFraction, "Throughput has no invented percentage ceiling")
        XCTAssertEqual(cells[4].windows.map(\.detail), ["1.5MB/s", "1.2MB/s", "300KB/s"])
        XCTAssertEqual(SystemUsageReading.rate(0), "0B/s")
        let absent = SystemUsageReading().snapshots
        XCTAssertTrue(absent.allSatisfy { !$0.hasReading && $0.headlineText == "—" })
        XCTAssertTrue(absent[2].statusMessage?.contains("unavailable") == true)
        XCTAssertEqual(cells[5].headlineText, "80% ⚡︎")
        XCTAssertEqual(cells[5].ringFraction, 0.8)
        XCTAssertEqual(cells[5].bandOverride, .ample, "A nearly full battery is healthy")
        XCTAssertEqual(cells[6].headlineText, "25.0W")
        XCTAssertNil(cells[6].ringFraction, "Power has no invented percentage limit")
        XCTAssertEqual(cells[6].windows.map(\.detail), ["25.0W", "40.0W", "15.0W"])
    }

    static var reading: SystemUsageReading {
        .init(cpu: 0, memory: .init(used: 8 * 1_073_741_824, total: 16 * 1_073_741_824),
              gpu: 0.42, disk: .init(used: 250_000_000_000, total: 1_000_000_000_000),
              network: .init(received: 1_200_000, sent: 300_000),
              power: .init(battery: .init(fraction: 0.8, state: .charging),
                           telemetry: .init(systemWatts: 25, adapterWatts: 40, batteryWatts: 15)))
    }
}

@MainActor
final class SystemUsageIntegrationTests: XCTestCase {
    func testCoreGridFitsManyCoresAndPreservesHoverOnEveryEdge() async throws {
        var reading = SystemUsageTests.reading
        reading.cpuCores = (0..<64).map { .init(id: $0, fraction: $0 == 0 ? nil : Double($0 % 11) / 10) }
        var snapshot = reading.snapshots[0]
        snapshot.systemColor = .purple
        let model = NotchViewModel()
        model.screenSize = CGSize(width: 1440, height: 900)
        model.updateSnapshots([snapshot])
        model.hoveredIndex = 0
        let height = model.cardHeight(for: snapshot)
        XCTAssertLessThan(height, 450)
        XCTAssertEqual(NotchLayout.cpuCoreGridHeight(64), NotchLayout.cpuCoreGridHeight(10))
        XCTAssertEqual(NotchLayout.cpuCoreGridHeight(0), 0)
        for edge in NotchEdge.allCases {
            model.edge = edge
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .environment(\.codenotchHeadlessGlass, true))
            XCTAssertNotNil(renderer.cgImage)
        }
        let content = TooltipCard(snapshot: snapshot, now: Date())
            .padding(16).background(Color.black)
            .environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark)
        // ImageRenderer does not realize lazy scroll content; mount the native view.
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: hosting.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/codenotch-cpu-cores.png"))
        snapshot.cpuCores[0] = .init(id: 0, fraction: 0.9)
        model.updateSnapshots([snapshot])
        XCTAssertEqual(model.hoveredIndex, 0)
        XCTAssertEqual(model.snapshots[0].cpuCores[0].fraction, 0.9)
        XCTAssertEqual(model.cardHeight(for: snapshot), height)
    }

    func testEnrichedHoverCardsFitAndRenderWithNetworkSettings() throws {
        var reading = SystemUsageTests.reading
        reading.cpu = 0.4
        reading.cpuUser = 0.3
        reading.cpuSystem = 0.1
        reading.logicalCores = 10
        reading.cpuCores = (0..<12).map { .init(id: $0, fraction: Double($0) / 12) }
        reading.gpuDetails = .init(renderer: 0.82, tiler: 0.41, memoryUsed: 1_600_000_000)
        reading.thermalState = .nominal
        reading.uptime = 12345
        reading.memoryDetails = .init(wired: 3_000_000_000, compressed: 1_000_000_000, swapUsed: 500_000_000)
        reading.diskAvailableForFiles = 800_000_000_000
        reading.networkLink = .init(kind: .wifi, interface: "en0", rssi: -65, noise: -94, transmitMbps: 360)
        reading.networkInterfaces = ["en0"]
        reading.networkTotals = .init(received: 3_000_000_000, sent: 1_000_000_000)
        reading.networkMeasuredSeconds = 128
        reading.recent = ["cpu": .init(average: 0.35, peak: 0.8), "gpu": .init(average: 0.5, peak: 0.9),
                          "power": .init(average: 25, peak: 40)]
        reading.energy = .init(wattHours: 3.5, measuredSeconds: 600)
        reading.power = .init(battery: .init(fraction: 0.8, state: .charging, minutesRemaining: 45,
                                            health: "Good", lowPowerMode: false), telemetry: reading.power?.telemetry)
        let snapshots = reading.snapshots
        let model = NotchViewModel()
        model.snapshots = snapshots
        for snapshot in snapshots {
            XCTAssertLessThan(model.cardHeight(for: snapshot), 400)
        }
        let net = snapshots[4]
        let withoutButton = NotchLayout.cardHeight(windowCount: net.windows.count, hasPlan: true,
                                                   compactRowCount: net.compactRowCount)
        XCTAssertEqual(model.cardHeight(for: net), withoutButton + NotchLayout.blockSpacing + NotchLayout.cardBodyLineHeight,
                       accuracy: 0.001)
        XCTAssertEqual(NSWorkspace.shared.urlForApplication(toOpen: SystemNetworkLink.wifiSettingsURL)?.lastPathComponent,
                       "System Settings.app")
        for (suffix, indices) in [("system", [0, 1, 4]), ("power", [2, 3, 5, 6])] {
            let renderer = ImageRenderer(content: HStack(alignment: .top, spacing: 16) {
                ForEach(indices, id: \.self) { TooltipCard(snapshot: snapshots[$0], now: Date()) }
            }.padding(20).background(Color.black)
                .environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/codenotch-hover-\(suffix).png"))
        }
    }

    func testMeterColorsPersistIndependentlyAndReachTheNotch() throws {
        let name = "SystemUsageColors.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.systemUsageColors.isEmpty)
        let colors: [AccentColorChoice] = [.blue, .green, .purple, .orange, .teal, .yellow, .pink]
        let snapshots = SystemUsageTests.reading.snapshots
        for (snapshot, color) in zip(snapshots, colors) {
            preferences.systemUsageColors[snapshot.id] = color
        }
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.systemUsageColors, preferences.systemUsageColors)
        let fleet = NotchFleet(scope: .mainDisplay, edge: .top)
        defer { fleet.stop() }
        let providers = Fixtures.snapshots()
        fleet.setSnapshots(providers)
        fleet.setSystemSnapshots(snapshots, colors: reloaded.systemUsageColors)
        XCTAssertEqual(Array(fleet.menuModel.snapshots.prefix(providers.count)), providers)
        XCTAssertEqual(fleet.menuModel.snapshots.suffix(7).compactMap(\.systemColor), colors)

        preferences.systemUsageColors["system-cpu"] = nil
        var next = SystemUsageTests.reading
        next.gpu = 1
        fleet.setSystemSnapshots(next.snapshots, colors: preferences.systemUsageColors)
        let meters = Array(fleet.menuModel.snapshots.suffix(7))
        XCTAssertNil(meters[0].systemColor)
        XCTAssertEqual(meters[2].systemColor, .purple, "A full meter keeps its chosen colour")
        XCTAssertEqual(Array(meters.dropFirst().compactMap(\.systemColor)), Array(colors.dropFirst()))
        XCTAssertNil(Preferences(defaults: defaults).systemUsageColors["system-cpu"])
        defaults.set(["system-cpu": "unknown", "system-memory": AccentColorChoice.green.rawValue],
                     forKey: "systemUsageColors")
        XCTAssertEqual(Preferences(defaults: defaults).systemUsageColors, ["system-memory": .green])
    }

    func testSystemUpdatesPreserveProviderReadingsAndHover() {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .top)
        defer { fleet.stop() }
        let providers = Fixtures.snapshots()
        fleet.setSnapshots(providers)
        fleet.setSystemSnapshots(SystemUsageTests.reading.snapshots)
        let model = fleet.menuModel
        model.hoveredIndex = providers.count + 2
        var updated = SystemUsageTests.reading
        updated.gpu = 0.75
        fleet.setSystemSnapshots(updated.snapshots)
        XCTAssertEqual(Array(model.snapshots.prefix(providers.count)), providers)
        XCTAssertEqual(model.hoveredSnapshot?.id, "system-gpu")
        XCTAssertEqual(model.hoveredSnapshot?.usedFraction, 0.75)
        fleet.setSnapshots([])
        XCTAssertEqual(model.snapshots.count, 7, "System meters work without any connected accounts")
        fleet.setSystemSnapshots([])
        XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertNil(model.hoveredIndex)
    }

    func testDisablingPersistsAndCancelsPublication() async throws {
        let name = "SystemUsageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.showsSystemUsage)
        preferences.showsSystemUsage = false
        XCTAssertFalse(Preferences(defaults: defaults).showsSystemUsage)
        let monitor = SystemUsageMonitor()
        monitor.setEnabled(true)
        XCTAssertEqual(monitor.snapshots.count, 7)
        XCTAssertTrue(monitor.snapshots.allSatisfy { $0.statusMessage == "Sampling…" })
        var counts: [Int] = []
        let subscription = monitor.$snapshots.sink { counts.append($0.count) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(counts.contains(0), "Wake must not remove cells or their hovered identity")
        subscription.cancel()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, monitor.snapshots.first?.hasReading != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(monitor.snapshots.first?.hasReading, true)
        let liveID = monitor.snapshots.first?.id
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(monitor.snapshots.first?.id, liveID)
        XCTAssertNotEqual(monitor.snapshots.first?.statusMessage, "Sampling…",
                          "Wake keeps the last reading instead of starting the period over")
        monitor.setEnabled(false)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertTrue(monitor.snapshots.isEmpty)
    }

    func testSystemCellsAndTooltipsRenderOnEveryEdge() throws {
        for edge in NotchEdge.allCases {
            let model = NotchViewModel()
            model.edge = edge
            model.isExpanded = true
            model.surfaceStyle = .solid
            model.snapshots = SystemUsageTests.reading.snapshots
            let size = model.panelSize
            let renderer = ImageRenderer(content: NotchRootView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.codenotchHeadlessGlass, true)
                .environment(\.colorScheme, .dark))
            XCTAssertNotNil(renderer.cgImage)
        }
        let snapshots = zip(SystemUsageTests.reading.snapshots,
                            [AccentColorChoice.blue, .green, .purple, .orange, .teal, .yellow, .pink]).map {
            var snapshot = $0.0
            snapshot.systemColor = $0.1
            return snapshot
        }
        for snapshot in snapshots {
            let renderer = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date())
                .environment(\.codenotchHeadlessGlass, true)
                .environment(\.colorScheme, .dark))
            XCTAssertNotNil(renderer.cgImage)
        }
        if let path = ProcessInfo.processInfo.environment["SYSTEM_USAGE_RENDER_PATH"] {
            let renderer = ImageRenderer(content: VStack(spacing: 24) {
                HStack(spacing: 20) {
                    ForEach(snapshots) { ProviderCell(snapshot: $0) }
                }
                HStack(alignment: .top, spacing: 16) {
                    TooltipCard(snapshot: snapshots[5], now: Date())
                    TooltipCard(snapshot: snapshots[6], now: Date())
                }
            }.padding(24).background(Color.black)
                .environment(\.codenotchHeadlessGlass, true)
                .environment(\.colorScheme, .dark))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
