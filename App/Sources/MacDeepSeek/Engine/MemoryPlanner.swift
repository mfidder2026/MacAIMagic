import Foundation

/// The Mac memory plan for DeepSeek-V4.1-Flash on unified memory.
///
/// - Dense weights (attention, shared experts, router, mHC, embeddings), the KV cache and compute buffers go on the GPU.
/// - Routed experts go on the GPU layer by layer while they fit under the GPU's wired limit; the first `cpuMoELayers`
///   layers keep their experts on the CPU, read through mmap from the page cache (or the SSD when it is evicted).
/// - The Engram tables (161 GB) are never resident: llama.cpp reads the few rows a token needs from the SSD.
struct MemoryPlan {
    var physical: UInt64
    var gpuLimit: UInt64
    var suggestedWiredLimitMB: Int
    var dense: UInt64
    var experts: UInt64
    var engram: UInt64
    var overhead: UInt64
    var layers: Int
    var cpuMoELayers: Int
    var gpuExperts: UInt64
    var cpuExperts: UInt64
    var threads: Int
    var contextSize: Int
    var warnings: [String]

    /// Everything that wants to stay in memory while the model runs.
    var resident: UInt64 { dense + experts + overhead }
    var fitsInMemory: Bool { resident + MemoryPlanner.osHeadroom <= physical }
}

enum MemoryPlanner {
    /// Left for macOS, the app and a browser; less than this and the system starts swapping.
    static let osHeadroom: UInt64 = 8_000_000_000

    static func plan(index: GGUFIndex, system: SystemInfo, contextSize: Int, vision: Bool, gpuLimitOverride: UInt64? = nil) -> MemoryPlan {
        let perLayer = index.expertBytesPerLayer
        let layers = max(index.layerCount, (perLayer.keys.max() ?? -1) + 1)
        let experts = perLayer.values.reduce(0, +)
        // KV: DeepSeek-V4.1 compresses its attention cache, about 0.7 GB per 128K tokens; compute buffers ~2.5 GB at ubatch 512
        let kv = UInt64(Double(contextSize) / 131_072 * 0.8e9) + 400_000_000
        let overhead = kv + 2_500_000_000 + (vision ? 1_500_000_000 : 0)
        let gpuLimit = gpuLimitOverride ?? system.effectiveGPULimit
        let suggestedMB = Int((system.physical - osHeadroom) >> 20)

        // the fewest CPU layers whose remainder fits on the GPU
        let budget = Int64(gpuLimit) - Int64(index.denseBytes) - Int64(overhead)
        var cpuLayers = 0
        var onGPU = experts
        while cpuLayers < layers && Int64(onGPU) > budget {
            onGPU -= perLayer[cpuLayers] ?? 0
            cpuLayers += 1
        }

        var warnings: [String] = []
        if gpuLimit + 4_000_000_000 < system.physical - osHeadroom {
            warnings.append("De GPU mag nu \(gpuLimit.gb) vastzetten. Verhoog de limiet naar \((UInt64(suggestedMB) << 20).gb) met de knop hieronder, dan staan alle experts op de GPU.")
        }
        let resident = index.denseBytes + experts + overhead
        if resident + osHeadroom > system.physical {
            let short = resident + osHeadroom - system.physical
            warnings.append("Het model past niet helemaal in het geheugen: ongeveer \(short.gb) aan experts wordt tijdens het praten van de SSD gelezen. Dat werkt, maar is trager.")
        }
        if Int64(index.denseBytes) + Int64(overhead) > Int64(gpuLimit) {
            warnings.append("Zelfs de vaste gewichten passen niet onder de GPU-limiet; verhoog de limiet of verklein de context.")
        }

        return MemoryPlan(
            physical: system.physical, gpuLimit: gpuLimit, suggestedWiredLimitMB: suggestedMB,
            dense: index.denseBytes, experts: experts, engram: index.engramBytes, overhead: overhead,
            layers: layers, cpuMoELayers: cpuLayers, gpuExperts: onGPU, cpuExperts: experts - onGPU,
            threads: max(4, system.performanceCores), contextSize: contextSize, warnings: warnings)
    }
}

private extension SystemInfo {
    var physical: UInt64 { physicalMemory }
}
