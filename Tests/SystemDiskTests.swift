import SwiftUI
import XCTest
@testable import PenguinNotch

final class SystemDiskTests: XCTestCase {
    func testLocalPartitionsKeepIndependentCapacitiesAndAliasesDoNotDuplicate() throws {
        let home = try volume("HOME", "/", used: 250, total: 1000)
        let usb = try volume("USB", "/Volumes/USB", used: 300, total: 500)
        let alias = try volume("usb", "/Volumes/USB Alias", used: 300, total: 500)
        let partition = try volume("OTHER", "/Volumes/Other", used: 40, total: 100)
        let result = SystemDiskVolume.additional([alias, home, partition, usb], homeUUID: "home", homePath: "/")
        XCTAssertEqual(result.map(\.id), ["uuid:other", "uuid:usb"])
        XCTAssertEqual(result.map { $0.capacity.fraction }, [0.4, 0.6])
        XCTAssertEqual(result.map(\.free), [60, 200])
        // Shared APFS space is never summed into a fabricated physical total.
        let system = try volume("SYSTEM", "/", used: 250, total: 1000)
        XCTAssertTrue(SystemDiskVolume.additional([home, system], homeUUID: "HOME",
                                                   homePath: "/System/Volumes/Data").isEmpty)
    }

    func testUnreadableAndNetworkVolumesAreNotInventedAsEmptyDisks() throws {
        for total in [nil, 0, -1] as [Int?] {
            XCTAssertNil(SystemDiskVolume(uuid: nil, name: nil, mountPath: "/Volumes/Test",
                                          total: total, available: 1, isLocal: true))
        }
        for available in [nil, -1] as [Int?] {
            XCTAssertNil(SystemDiskVolume(uuid: nil, name: nil, mountPath: "/Volumes/Test",
                                          total: 100, available: available, isLocal: true))
        }
        for local in [nil, false] as [Bool?] {
            XCTAssertNil(SystemDiskVolume(uuid: nil, name: nil, mountPath: "/Volumes/Test",
                                          total: 100, available: 80, isLocal: local))
        }
        let clamped = try XCTUnwrap(SystemDiskVolume(uuid: "  ", name: "", mountPath: "/Volumes/Test/",
                                                   total: 100, available: 101, isLocal: true))
        XCTAssertEqual(clamped.capacity.used, 0)
        XCTAssertEqual(clamped.free, 100)
        XCTAssertEqual(clamped.id, "path:/Volumes/Test")
        XCTAssertEqual(clamped.name, "/Volumes/Test")
    }

    func testSlowScanIsSingleFlightAndUnmountRejectsItsLateResult() async throws {
        let old = try volume("OLD", "/Volumes/Old", used: 20, total: 100)
        let current = try volume("NEW", "/Volumes/New", used: 30, total: 100)
        let fixture = DiskReadFixture(first: [old], subsequent: [current], blockFirst: true)
        defer { fixture.release.signal() }
        let sampler = SystemDiskSampler(read: { fixture.read() })
        let first = await sampler.snapshot(at: 0)
        XCTAssertTrue(first.isEmpty)
        let started = await Task.detached { fixture.waitUntilStarted() }.value
        XCTAssertEqual(started, .success)
        let pending = await sampler.snapshot(at: 1)
        XCTAssertTrue(pending.isEmpty, "Slow storage must not block other system sampling")
        await sampler.invalidate()
        _ = await sampler.snapshot(at: 2)
        XCTAssertEqual(fixture.calls, 1, "Invalidation must not start a concurrent disk scan")
        fixture.release.signal()
        let result = try await waitForVolumes(sampler, at: 2, expected: [current])
        XCTAssertEqual(result.map(\.id), ["uuid:new"], "A removed drive must not return through a late scan")
        XCTAssertEqual(fixture.calls, 2)
    }

    func testRefreshReplacesTheListAndMountInvalidationSkipsTheCache() async throws {
        let disk = try volume("USB", "/Volumes/USB", used: 60, total: 100)
        let fixture = DiskReadFixture(first: [disk], subsequent: [])
        let sampler = SystemDiskSampler(read: { fixture.read() })
        _ = try await waitForVolumes(sampler, at: 0, expected: [disk])
        for time in [1.0, 10, 29] { _ = await sampler.snapshot(at: time) }
        XCTAssertEqual(fixture.calls, 1)
        _ = await sampler.snapshot(at: 30)
        _ = try await waitForVolumes(sampler, at: 30, expected: [])
        XCTAssertEqual(fixture.calls, 2)
        await sampler.invalidate()
        _ = await sampler.snapshot(at: 31)
        let deadline = Date().addingTimeInterval(2)
        while fixture.calls < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.calls, 3)
    }

    @MainActor
    func testExternalDiskCardRendersInEnglishAndKorean() throws {
        let previousLocale = L10n.testLocale
        defer { L10n.testLocale = previousLocale }
        var reading = SystemUsageTests.reading
        reading.diskAvailableForFiles = 800_000_000_000
        reading.diskVolumes = [try volume("USB", "/Volumes/Portable SSD", used: 300_000_000_000, total: 500_000_000_000),
                               try volume("ARCHIVE", "/Volumes/Archive", used: 40_000_000_000, total: 100_000_000_000)]
        for (language, suffix, title) in [(AppLanguage.english, "en", "Other mounted volumes"),
                                           (AppLanguage.korean, "ko", "다른 마운트된 볼륨")] {
            L10n.testLocale = language.locale
            XCTAssertEqual(L10n.t("Other mounted volumes"), title)
            let renderer = ImageRenderer(content: TooltipCard(snapshot: reading.snapshots[3], now: Date())
                .environment(\.penguinnotchHeadlessGlass, true)
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.colorScheme, .dark))
            let image = try XCTUnwrap(renderer.cgImage)
            if let path = ProcessInfo.processInfo.environment["DISK_RENDER_DIRECTORY"] {
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("disks-\(suffix).png"))
            }
        }
    }

    @MainActor
    func testDiskHoverPreservesHeadlineAndScrollsLongVolumeListsOnAllEdges() throws {
        var reading = SystemUsageTests.reading
        let original = reading.snapshots[3]
        reading.diskVolumes = try (0..<12).map {
            try volume("USB\($0)", "/Volumes/A very long external disk partition \($0)", used: 60, total: 100)
        }
        let disk = reading.snapshots[3]
        XCTAssertEqual(disk.headlineText, original.headlineText)
        XCTAssertEqual(disk.usedFraction, original.usedFraction)
        XCTAssertEqual(disk.diskVolumes.count, 12)
        var unreadableHome = reading
        unreadableHome.disk = nil
        XCTAssertEqual(unreadableHome.snapshots[3].headlineText, "—")
        XCTAssertEqual(unreadableHome.snapshots[3].diskVolumes.count, 12)
        let model = NotchViewModel()
        model.screenSize = CGSize(width: 640, height: 480)
        for edge in NotchEdge.allCases {
            model.edge = edge
            model.snapshots = [disk]
            model.hoveredIndex = 0
            XCTAssertGreaterThan(model.cardHeight(for: disk), model.tooltipHeightLimit)
            XCTAssertLessThanOrEqual(model.tooltipCardSize(for: disk).height, model.tooltipHeightLimit * model.hoverTextScale)
            let renderer = ImageRenderer(content: TooltipCard(snapshot: disk, now: Date())
                .environment(\.tooltipHeightLimit, 300)
                .environment(\.penguinnotchHeadlessGlass, true)
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.colorScheme, .dark))
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.height, 300)
        }
    }

    private func volume(_ uuid: String, _ path: String, used: Int, total: Int) throws -> SystemDiskVolume {
        try XCTUnwrap(SystemDiskVolume(uuid: uuid, name: URL(fileURLWithPath: path).lastPathComponent,
                                      mountPath: path, total: total, available: total - used, isLocal: true))
    }

    private func waitForVolumes(_ sampler: SystemDiskSampler, at time: TimeInterval,
                                expected: [SystemDiskVolume]) async throws -> [SystemDiskVolume] {
        let deadline = Date().addingTimeInterval(2)
        var result = await sampler.snapshot(at: time)
        while result != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            result = await sampler.snapshot(at: time)
        }
        XCTAssertEqual(result, expected)
        return result
    }
}

private final class DiskReadFixture: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let first: [SystemDiskVolume]
    private let subsequent: [SystemDiskVolume]
    private let blockFirst: Bool
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(first: [SystemDiskVolume], subsequent: [SystemDiskVolume], blockFirst: Bool = false) {
        self.first = first
        self.subsequent = subsequent
        self.blockFirst = blockFirst
    }

    func read() -> [SystemDiskVolume] {
        let call = lock.withLock { count += 1; return count }
        started.signal()
        if call == 1, blockFirst { _ = release.wait(timeout: .now() + 5) }
        return call == 1 ? first : subsequent
    }

    func waitUntilStarted() -> DispatchTimeoutResult { started.wait(timeout: .now() + 2) }
}
