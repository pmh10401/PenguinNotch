import Foundation

struct SystemDiskVolume: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mountPath: String
    let capacity: SystemUsageReading.Capacity
    var free: UInt64 { capacity.total - capacity.used }

    init?(uuid: String?, name: String?, mountPath: String, total: Int?, available: Int?, isLocal: Bool?) {
        guard isLocal == true, mountPath.hasPrefix("/"),
              let total, total > 0, let available, available >= 0 else { return nil }
        let path = URL(fileURLWithPath: mountPath, isDirectory: true).standardizedFileURL.path
        let uuid = uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        id = uuid.flatMap { $0.isEmpty ? nil : "uuid:\($0.lowercased())" } ?? "path:\(path)"
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? path
        self.mountPath = path
        capacity = .init(used: UInt64(total - min(total, available)), total: UInt64(total))
    }

    static func additional(_ volumes: [Self], homeUUID: String?, homePath: String?) -> [Self] {
        let homeID = homeUUID.map { "uuid:\($0.lowercased())" }
        var seen = Set<String>()
        return volumes.sorted { $0.mountPath < $1.mountPath }.filter {
            guard $0.id != homeID, $0.mountPath != homePath else { return false }
            // APFS exposes the System/Data pair through one user-facing root.
            if homePath == "/System/Volumes/Data", $0.mountPath == "/" { return false }
            return seen.insert($0.id).inserted
        }
    }

    static func readMounted() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeUUIDStringKey, .volumeNameKey,
                                       .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeURLKey]
        // Capacity calls can block on a sleeping driver, and run exclusively
        // in the separate disk sampler below. Check local status before them.
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                              options: [.skipHiddenVolumes]) else { return [] }
        let home = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        let volumes = urls.compactMap { url -> Self? in
            guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
                  values.volumeIsLocal == true,
                  let all = try? url.resourceValues(forKeys: keys) else { return nil }
            return .init(uuid: all.volumeUUIDString, name: all.volumeName, mountPath: url.path,
                         total: all.volumeTotalCapacity, available: all.volumeAvailableCapacity,
                         isLocal: all.volumeIsLocal)
        }
        return additional(volumes, homeUUID: home?.volumeUUIDString, homePath: home?.volume?.path)
    }
}

/// One scan in flight; slow storage never holds up CPU/network sampling.
actor SystemDiskSampler {
    private let read: @Sendable () -> [SystemDiskVolume]
    private var volumes: [SystemDiskVolume] = []
    private var startedAt: TimeInterval?
    private var pending = false
    private var generation = 0

    init(read: @escaping @Sendable () -> [SystemDiskVolume] = { SystemDiskVolume.readMounted() }) {
        self.read = read
    }

    func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [SystemDiskVolume] {
        if !pending, startedAt.map({ time < $0 || time - $0 >= 30 }) ?? true {
            pending = true
            startedAt = time
            let generation = generation
            let read = read
            Task.detached(priority: .utility) {
                let result = read()
                await self.finish(result, generation: generation)
            }
        }
        return volumes
    }

    func invalidate() {
        generation += 1
        startedAt = nil
        volumes = []
    }

    private func finish(_ result: [SystemDiskVolume], generation: Int) {
        if generation == self.generation { volumes = result }
        pending = false
    }
}
