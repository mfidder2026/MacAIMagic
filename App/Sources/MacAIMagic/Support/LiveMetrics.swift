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

    /// The engine's own count of tokens written in the current answer (llama-server /slots), whoever asked for it.
    private var lastDecoded: Int?
    /// The engine is answering a request (from this app or from another client, such as the API).
    @Published private(set) var engineBusy = false
    private var engineRate: Double?
    private var polling = false

    private var timer: Timer?
    private var lastDiskRead: UInt64?
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastTick = Date()
    let totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1e9

    /// Twice a second while the engine runs, every 2 s when it does not (the charts redraw on every sample).
    var fast = false {
        didSet { if fast != oldValue { schedule() } }
    }

    /// Image tokens per second while an image is made (the image engine has no /slots); nil otherwise.
    var imageRate: Double? {
        didSet { if (imageRate == nil) != (oldValue == nil) { schedule() } }
    }
    var makingImage: Bool { imageRate != nil }

    /// The top of a speed scale: `base` for text, a round number above the speeds of the last minute and a half otherwise.
    func scale(base: Double) -> Double {
        let top = max(samples.map(\.tokensPerSec).max() ?? 0, current?.tokensPerSec ?? 0)
        guard top > base * 0.95 else { return base }
        return [100.0, 250, 500, 1000, 2500, 5000].first { top <= $0 * 0.95 } ?? 10000
    }

    init() { schedule() }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fast || imageRate != nil ? 0.5 : 2, repeats: true) { [weak self] _ in
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
        // the engine's own count when it answers (any client: this app, the API, tools), else the tokens this app streamed
        if fast { pollEngine(dt: dt) }
        let inst = imageRate ?? engineRate ?? Double(tokenCount) / dt
        tokenCount = 0
        let idle = imageRate.map { $0 == 0 } ?? engineRate.map { $0 == 0 } ?? (now.timeIntervalSince(lastStreamDate) > 1.5)
        lastTokenRate = idle ? 0 : (lastTokenRate * 0.6 + inst * 0.4)

        let mem = Self.memory()
        let s = Sample(t: now, gpu: Self.gpuUtilization(), cpu: cpu, wiredGB: mem.wired, usedGB: mem.used,
                       ssdMBs: ssd, tokensPerSec: lastTokenRate)
        current = s
        samples.append(s)
        let cutoff = now.addingTimeInterval(-Self.window)
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 { samples.removeFirst(first) }
    }

    /// Reads n_decoded of the busy slot; the difference with the last sample is the writing speed.
    private func pollEngine(dt: Double) {
        guard !polling else { return }
        polling = true
        let st = Settings.shared
        var req = URLRequest(url: URL(string: "http://\(st.host):\(st.port)/slots")!)
        req.timeoutInterval = 1
        if !st.apiKey.isEmpty { req.setValue("Bearer \(st.apiKey)", forHTTPHeaderField: "Authorization") }
        Task { [weak self] in
            defer { Task { @MainActor in self?.polling = false } }
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                await MainActor.run { self?.engineRate = nil; self?.lastDecoded = nil }
                return
            }
            let busy = slots.first { ($0["is_processing"] as? Bool) == true }
            await MainActor.run { if self?.engineBusy != (busy != nil) { self?.engineBusy = busy != nil } }
            let decoded = ((busy?["next_token"] as? [[String: Any]])?.first?["n_decoded"] as? Int) ?? 0
            await MainActor.run {
                guard let self else { return }
                if busy == nil {
                    self.engineRate = 0
                } else if let last = self.lastDecoded {
                    // a new answer starts again from 0
                    self.engineRate = Double(decoded >= last ? decoded - last : decoded) / dt
                }
                self.lastDecoded = busy == nil ? nil : decoded
            }
        }
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
