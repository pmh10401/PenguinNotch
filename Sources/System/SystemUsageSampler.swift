import Darwin
import Foundation
import IOKit

struct SystemUsageReading: Equatable, Sendable {
    struct Capacity: Equatable, Sendable {
        let used: UInt64
        let total: UInt64
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    struct NetworkRate: Equatable, Sendable {
        let received: Double
        let sent: Double
    }

    struct MemoryDetails: Equatable, Sendable {
        let wired: UInt64
        let compressed: UInt64
        let swapUsed: UInt64?
    }

    struct Recent: Equatable, Sendable {
        let average: Double
        let peak: Double
    }

    struct Energy: Equatable, Sendable {
        let wattHours: Double
        let measuredSeconds: TimeInterval
    }

    struct CoreLoad: Identifiable, Equatable, Sendable {
        /// Mach logical processor index; stable across consecutive samples.
        let id: Int
        let fraction: Double?
    }

    struct GPUDetails: Equatable, Sendable {
        let renderer: Double?
        let tiler: Double?
        let memoryUsed: UInt64?
    }

    var cpu: Double?
    var cpuUser: Double?
    var cpuSystem: Double?
    var memory: Capacity?
    var gpu: Double?
    var disk: Capacity?
    var network: NetworkRate?
    var power: SystemPowerReading?
    var memoryDetails: MemoryDetails?
    var diskAvailableForFiles: UInt64?
    var logicalCores: Int?
    var thermalState: ProcessInfo.ThermalState?
    var uptime: TimeInterval?
    var networkInterfaces: [String] = []
    var networkLink: SystemNetworkLink?
    var networkTotals: NetworkRate?
    var networkMeasuredSeconds: TimeInterval = 0
    var recent: [String: Recent] = [:]
    var energy: Energy?
    var cpuCores: [CoreLoad] = []
    var gpuDetails: GPUDetails?
}

/// A bounded, in-memory view of this sampling period; gaps are never billed as activity.
struct SystemUsageHistory {
    private var samples: [(time: TimeInterval, values: [String: Double])] = []
    private var previousTime: TimeInterval?
    private var previousWatts: Double?
    private var received = 0.0
    private var sent = 0.0
    private var networkSeconds = 0.0
    private var wattHours = 0.0
    private var powerSeconds = 0.0

    mutating func enrich(_ reading: inout SystemUsageReading, at time: TimeInterval) {
        guard time.isFinite else { return }
        let elapsed = previousTime.map { time - $0 }
        let continuous = elapsed.map { $0 > 0 && $0 <= 10 } ?? false
        let watts = (reading.power?.telemetry?.systemWatts).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if continuous, let elapsed {
            if let network = reading.network, network.received.isFinite, network.sent.isFinite,
               network.received >= 0, network.sent >= 0 {
                received += network.received * elapsed
                sent += network.sent * elapsed
                networkSeconds += elapsed
            }
            if let watts, let previousWatts {
                wattHours += (watts + previousWatts) / 2 * elapsed / 3600
                powerSeconds += elapsed
            }
        } else { samples.removeAll(keepingCapacity: true) }
        previousTime = time
        previousWatts = watts
        var values: [String: Double] = [:]
        for (id, value) in [("cpu", reading.cpu), ("gpu", reading.gpu), ("power", watts)] {
            if let value, value.isFinite, value >= 0 { values[id] = value }
        }
        samples.append((time, values))
        samples.removeAll { time - $0.time >= 60 }
        if samples.count > 61 { samples.removeFirst(samples.count - 61) }
        reading.recent = [:]
        for id in values.keys {
            let values = samples.compactMap { $0.values[id] }
            guard values.count >= 2 else { continue }
            reading.recent[id] = .init(average: values.reduce(0, +) / Double(values.count), peak: values.max()!)
        }
        if networkSeconds > 0 {
            reading.networkTotals = .init(received: received, sent: sent)
            reading.networkMeasuredSeconds = networkSeconds
        }
        if powerSeconds > 0 { reading.energy = .init(wattHours: wattHours, measuredSeconds: powerSeconds) }
    }
}

struct SystemCPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func fraction(since previous: Self) -> Double? {
        fractions(since: previous).map { $0.user + $0.system }
    }

    func fractions(since previous: Self) -> (user: Double, system: Double)? {
        // Mach exports wrapping 32-bit counters, even on a 64-bit Mac.
        let user = UInt64(user &- previous.user) + UInt64(nice &- previous.nice)
        let system = UInt64(system &- previous.system)
        let total = user + system + UInt64(idle &- previous.idle)
        return total > 0 ? (Double(user) / Double(total), Double(system) / Double(total)) : nil
    }

    static func coreLoads(current: [Self], previous: [Self]?, elapsed: TimeInterval?) -> [SystemUsageReading.CoreLoad] {
        let comparable = previous?.count == current.count
            && elapsed.map { $0.isFinite && $0 > 0 && $0 <= 10 } == true
        return current.enumerated().map { index, ticks in
            .init(id: index, fraction: comparable ? ticks.fraction(since: previous![index]) : nil)
        }
    }
}

struct SystemNetworkBytes: Sendable {
    let received: UInt64
    let sent: UInt64

    static func rate(current: [String: Self], previous: [String: Self],
                     elapsed: TimeInterval) -> SystemUsageReading.NetworkRate? {
        guard elapsed.isFinite, elapsed > 0, elapsed <= 10 else { return nil }
        var received = 0.0, sent = 0.0
        var comparable = current.isEmpty && previous.isEmpty
        for (name, bytes) in current {
            guard let old = previous[name], bytes.received >= old.received,
                  bytes.sent >= old.sent else { continue }
            comparable = true
            received += Double(bytes.received - old.received)
            sent += Double(bytes.sent - old.sent)
        }
        guard comparable else { return nil }
        return .init(received: received / elapsed, sent: sent / elapsed)
    }
}

/// Native reads run off the main actor; one sampler serves every display.
actor SystemUsageSampler {
    private let host = mach_host_self()
    private var previousCPU: SystemCPUTicks?
    private var previousCores: [SystemCPUTicks]?
    private var previousNetwork: [String: SystemNetworkBytes]?
    private var previousTime: TimeInterval?
    private var history = SystemUsageHistory()

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample() -> SystemUsageReading {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = readCPU()
        let cores = readCPUCores()
        let network = readNetwork()
        let elapsed = previousTime.map { now - $0 }
        let memory = readMemory()
        let disk = readDisk()
        let gpu = readGPU()
        var reading = SystemUsageReading(memory: memory?.capacity, gpu: gpu?.fraction, disk: disk?.capacity,
                                         power: SystemPowerReading.read(), memoryDetails: memory?.details,
                                         diskAvailableForFiles: disk?.availableForFiles,
                                         logicalCores: ProcessInfo.processInfo.activeProcessorCount,
                                         thermalState: ProcessInfo.processInfo.thermalState, uptime: now,
                                         networkInterfaces: network?.keys.sorted() ?? [], networkLink: SystemNetworkLink.read())
        reading.cpuCores = SystemCPUTicks.coreLoads(current: cores ?? [], previous: previousCores, elapsed: elapsed)
        reading.gpuDetails = gpu?.details
        // First readings and long gaps establish a baseline, never a since-boot average.
        if let elapsed, elapsed > 0, elapsed <= 10 {
            if let cpu, let previousCPU, let fractions = cpu.fractions(since: previousCPU) {
                reading.cpu = fractions.user + fractions.system
                reading.cpuUser = fractions.user
                reading.cpuSystem = fractions.system
            }
            if let network, let previousNetwork {
                reading.network = SystemNetworkBytes.rate(current: network, previous: previousNetwork,
                                                          elapsed: elapsed)
            }
        }
        previousTime = now
        previousCPU = cpu
        previousCores = cores
        previousNetwork = network
        history.enrich(&reading, at: now)
        return reading
    }

    private func readCPU() -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                     idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readCPUCores() -> [SystemCPUTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard processorCount > 0, Int(count) >= Int(processorCount) * states else { return nil }
        return (0..<Int(processorCount)).map { core in
            let offset = core * states
            return SystemCPUTicks(user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                                  system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                                  idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                                  nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
    }

    private func readMemory() -> (capacity: SystemUsageReading.Capacity, details: SystemUsageReading.MemoryDetails)? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS,
              pageSize > 0 else { return nil }
        // Anonymous memory + wired + physical compressor storage, excluding purgeable pages.
        // File-backed cache and the uncompressed size of compressed pages are not added again.
        let anonymous = UInt64(info.internal_page_count)
        let purgeable = min(anonymous, UInt64(info.purgeable_count))
        let pages = anonymous - purgeable + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : nil
        return (.init(used: min(total, pages * UInt64(pageSize)), total: total),
                .init(wired: UInt64(info.wire_count) * UInt64(pageSize),
                      compressed: UInt64(info.compressor_page_count) * UInt64(pageSize), swapUsed: swapUsed))
    }

    private func readDisk() -> (capacity: SystemUsageReading.Capacity, availableForFiles: UInt64?)? {
        let volume = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                               .volumeAvailableCapacityKey,
                                                               .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0, available >= 0 else { return nil }
        let forFiles = values.volumeAvailableCapacityForImportantUsage.flatMap {
            $0 >= 0 ? UInt64(min(Int64(total), $0)) : nil
        }
        return (.init(used: UInt64(max(0, total - available)), total: UInt64(total)), forFiles)
    }

    private func readGPU() -> (fraction: Double, details: SystemUsageReading.GPUDetails)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                          &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var busiest: (fraction: Double, details: SystemUsageReading.GPUDetails)?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // ponytail: driver-published, undocumented statistic; show unavailable if absent.
            // A new driver needs a verified counter here, not a fabricated zero or sudo helper.
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                                 kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any],
                  let reading = Self.gpuReading(statistics: stats) else { continue }
            if busiest == nil || reading.fraction > busiest!.fraction { busiest = reading }
        }
        // Separate GPUs have separate capacities; summing their percentages would be misleading.
        return busiest
    }

    static func gpuReading(statistics: [String: Any]) -> (fraction: Double, details: SystemUsageReading.GPUDetails)? {
        func fraction(_ key: String) -> Double? {
            guard let value = (statistics[key] as? NSNumber)?.doubleValue,
                  value.isFinite, (0...100).contains(value) else { return nil }
            return value / 100
        }
        guard let total = fraction("Device Utilization %") else { return nil }
        let bytes = (statistics["In use system memory"] as? NSNumber)?.doubleValue
        let memory = bytes.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(UInt64.max) ? UInt64($0) : nil }
        return (total, .init(renderer: fraction("Renderer Utilization %"),
                             tiler: fraction("Tiler Utilization %"), memoryUsed: memory))
    }

    private func readNetwork() -> [String: SystemNetworkBytes]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size < 32 * 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        return Self.networkCounters(in: Data(data.prefix(size)))
    }

    static func networkCounters(in data: Data) -> [String: SystemNetworkBytes]? {
        data.withUnsafeBytes { buffer in
            var result: [String: SystemNetworkBytes] = [:]
            var offset = 0
            while offset < buffer.count {
                guard buffer.count - offset >= 4 else { return nil }
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= buffer.count - offset else { return nil }
                defer { offset += length }
                guard buffer[offset + 2] == RTM_VERSION, buffer[offset + 3] == RTM_IFINFO2 else { continue }
                guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                let info = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                      info.ifm_flags & IFF_LOOPBACK == 0 else { continue }
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(cString: nameBuffer)
                // ponytail: en* covers Mac Ethernet/Wi-Fi; exclude VPN/bridge/AirDrop copies.
                // Add verified physical interface types here if another transport is needed.
                guard name.hasPrefix("en") else { continue }
                result[name] = .init(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
            }
            return result
        }
    }
}
