import Foundation
import IOKit

/// Samples the Mac twice a second for the live charts: GPU and CPU load, memory, SSD reads, and the model's
/// writing speed (fed by the chat stream).
@MainActor
final class LiveMetrics: ObservableObject {
    struct Sample: Identifiable {
        let t: Date
        let gpu: Double          // %
        let cpu: Double          // %
        let wiredGB: Double
        let usedGB: Double
        let ssdMBs: Double       // MB/s read
        let tokensPerSec: Double
        var id: Date { t }
    }

    static let window: TimeInterval = 90
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var current: Sample?
    /// Tokens streamed since the last sample (the chat client adds to it).
    private var tokenCount = 0
    private var lastTokenRate = 0.0
    private var lastStreamDate = Date.distantPast

    private var timer: Timer?
    private var lastDiskRead: UInt64?
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastTick = Date()
    let totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1e9

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func addTokens(_ n: Int) {
        tokenCount += n
        lastStreamDate = Date()
    }

    private func sample() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now

        let disk = Self.diskBytesRead()
        let ssd = lastDiskRead.map { disk >= $0 ? Double(disk - $0) / dt / 1e6 : 0 } ?? 0
        lastDiskRead = disk

        let cpuNow = Self.cpuTicks()
        var cpu = 0.0
        if let last = lastCPU, cpuNow.total > last.total {
            cpu = Double(cpuNow.busy - last.busy) / Double(cpuNow.total - last.total) * 100
        }
        lastCPU = cpuNow

        // smooth the token rate a little; drop to zero shortly after the stream stops
        let inst = Double(tokenCount) / dt
        tokenCount = 0
        lastTokenRate = now.timeIntervalSince(lastStreamDate) > 1.5 ? 0 : (lastTokenRate * 0.6 + inst * 0.4)

        let mem = Self.memory()
        let s = Sample(t: now, gpu: Self.gpuUtilization(), cpu: cpu, wiredGB: mem.wired, usedGB: mem.used,
                       ssdMBs: ssd, tokensPerSec: lastTokenRate)
        current = s
        samples.append(s)
        let cutoff = now.addingTimeInterval(-Self.window)
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 { samples.removeFirst(first) }
    }

    // MARK: - counters

    /// "Device Utilization %" of the GPU, from the IOAccelerator's performance statistics.
    static func gpuUtilization() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var result = 0.0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = stats["Device Utilization %"] as? NSNumber {
                result = max(result, util.doubleValue)
            }
        }
        return result
    }

    /// Bytes read since boot, summed over all block storage drivers (the internal SSD).
    static func diskBytesRead() -> UInt64 {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var total: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let bytes = stats["Bytes (Read)"] as? NSNumber {
                total += bytes.uint64Value
            }
        }
        return total
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return (busy, total)
    }

    static func memory() -> (wired: Double, used: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let page = Double(vm_kernel_page_size)
        let wired = Double(stats.wire_count) * page / 1e9
        let used = (Double(stats.wire_count) + Double(stats.active_count) + Double(stats.compressor_page_count)) * page / 1e9
        return (wired, used)
    }
}
