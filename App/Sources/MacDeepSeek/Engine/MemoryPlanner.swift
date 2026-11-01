import Foundation

/// The memory plan for a large MoE model on unified memory.
///
/// - Dense weights (attention, shared experts, router, embeddings), the KV cache and compute buffers go on the GPU.
/// - Routed experts go on the GPU layer by layer while they fit; the first `cpuMoELayers` layers keep their experts on
///   the CPU, read through mmap from the page cache, or from the SSD when the model is larger than memory.
/// - DeepSeek's Engram tables are never resident: llama.cpp reads the few rows a token needs from the SSD.
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
    /// Expert bytes that do not fit in memory at all and come from the SSD as they are needed.
    var streamedExperts: UInt64 { fitsInMemory ? 0 : resident + MemoryPlanner.osHeadroom - physical }
}

enum MemoryPlanner {
    /// Left for macOS, the app and a browser; less than this and the system starts swapping.
    static let osHeadroom: UInt64 = 8_000_000_000

    /// For a model larger than memory: the share of the memory left for experts that is wired on the GPU (whole layers,
    /// fixed); the rest stays page cache, which keeps the experts that are actually used, across all layers.
    static var streamingGPUShare: Double {
        let v = UserDefaults.standard.double(forKey: "streamingGPUShare")
        return v > 0 ? v : 0.5
    }

    /// `extraGPU` / `extraPhysical`: memory that helper Macs in a cluster add (their GPUs hold some of the layers).
    static func plan(index: GGUFIndex, system: SystemInfo, contextSize: Int, vision: Bool, gpuLimitOverride: UInt64? = nil,
                     extraGPU: UInt64 = 0, extraPhysical: UInt64 = 0) -> MemoryPlan {
        let perLayer = index.expertBytesPerLayer
        let layers = max(index.layerCount, (perLayer.keys.max() ?? -1) + 1)
        let experts = perLayer.values.reduce(0, +)
        // KV: compressed attention caches are small (DeepSeek ~0.7 GB per 128K); compute buffers ~2.5 GB at ubatch 1024
        let kv = UInt64(Double(contextSize) / 131_072 * 0.8e9) + 400_000_000
        let overhead = kv + 2_500_000_000 + (vision ? 1_500_000_000 : 0)
        let physical = system.physicalMemory + extraPhysical
        let gpuLimit = (gpuLimitOverride ?? system.effectiveGPULimit) + extraGPU
        let suggestedMB = Int((system.physicalMemory - osHeadroom) >> 20)

        var budget = Int64(gpuLimit) - Int64(index.denseBytes) - Int64(overhead)
        let fits = index.denseBytes + experts + overhead + osHeadroom <= physical
        if !fits {
            // larger than memory: leave part of it to the page cache for the streamed layers
            let expertRAM = Int64(physical) - Int64(osHeadroom) - Int64(index.denseBytes) - Int64(overhead)
            budget = min(budget, Int64(Double(max(expertRAM, 0)) * streamingGPUShare))
        }
        // the fewest CPU layers whose remainder fits on the GPU
        var cpuLayers = 0
        var onGPU = experts
        while cpuLayers < layers && Int64(onGPU) > budget {
            onGPU -= perLayer[cpuLayers] ?? 0
            cpuLayers += 1
        }

        var warnings: [String] = []
        if fits && extraGPU == 0 && gpuLimit + 4_000_000_000 < physical - osHeadroom && cpuLayers > 0 {
            warnings.append("De GPU mag nu \(gpuLimit.gb) vastzetten. Verhoog de limiet naar \((UInt64(suggestedMB) << 20).gb) met de knop hieronder, dan staan alle experts op de GPU.")
        }
        if !fits {
            let short = index.denseBytes + experts + overhead + osHeadroom - physical
            warnings.append("Dit model is groter dan het geheugen: ongeveer \(short.gb) aan experts komt tijdens het schrijven van de SSD. Dat werkt, maar is trager.")
        }
        if Int64(index.denseBytes) + Int64(overhead) > Int64(gpuLimit) {
            warnings.append("Zelfs de vaste gewichten passen niet onder de GPU-limiet; verhoog de limiet of verklein de context.")
        }

        return MemoryPlan(
            physical: physical, gpuLimit: gpuLimit, suggestedWiredLimitMB: suggestedMB,
            dense: index.denseBytes, experts: experts, engram: index.engramBytes, overhead: overhead,
            layers: layers, cpuMoELayers: cpuLayers, gpuExperts: onGPU, cpuExperts: experts - onGPU,
            threads: max(4, system.performanceCores), contextSize: contextSize, warnings: warnings)
    }
}
