import Foundation
import Metal

/// What this Mac has: chip, unified memory, the GPU's working-set limit, free disk.
struct SystemInfo {
    let chip: String
    let physicalMemory: UInt64
    let performanceCores: Int
    /// Metal's recommendedMaxWorkingSetSize: how much the GPU may keep resident.
    let gpuWorkingSet: UInt64
    /// iogpu.wired_limit_mb (0 = the macOS default, about 75% of memory).
    let wiredLimitMB: Int
    let freeDisk: UInt64

    static func current() -> SystemInfo {
        let device = MTLCreateSystemDefaultDevice()
        let free = (try? Paths.appSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return SystemInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            gpuWorkingSet: device?.recommendedMaxWorkingSetSize ?? 0,
            wiredLimitMB: sysctlInt("iogpu.wired_limit_mb") ?? 0,
            freeDisk: UInt64(max(free, 0))
        )
    }

    /// Memory the GPU can wire: the raised limit when set, else Metal's recommendation.
    var effectiveGPULimit: UInt64 {
        wiredLimitMB > 0 ? UInt64(wiredLimitMB) << 20 : gpuWorkingSet
    }

    /// Pages macOS would hand out right now without swapping (free + inactive + purgeable + speculative).
    static func availableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
                + UInt64(stats.speculative_count)) * page
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            var v32: Int32 = 0
            size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &v32, &size, nil, 0) == 0 else { return nil }
            return Int(v32)
        }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}

extension UInt64 {
    var gb: String { String(format: "%.1f GB", Double(self) / 1e9) }
}
