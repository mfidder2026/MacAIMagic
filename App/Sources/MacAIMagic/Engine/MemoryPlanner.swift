import Foundation

/// The memory plan for a large MoE model on unified memory.
///
/// - Dense weights (attention, shared experts, router, embeddings), the KV cache and compute buffers go on the GPU.
/// - A model that fits in memory: routed experts go on the GPU layer by layer while they fit; the first layers keep
///   their experts in memory for the CPU (`--n-cpu-moe`).
/// - A model larger than memory: every expert stays mapped from the file, and part of the GPU becomes a cache of the
///   experts the conversation uses most (llama.cpp's MoE cache, `--moe-cache-mib`). The GPU computes all experts; a
///   missing one is read from the SSD with many parallel reads (our patch) when its layer needs it.
/// - In a cluster the helpers hold whole layers on their GPU, the first layers (llama.cpp puts RPC devices first),
///   and this Mac the rest.
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
    /// Layers whose experts stay in this Mac's memory instead of on its GPU.
    var hostExpertLayers: [Int]
    var gpuExperts: UInt64
    var cpuExperts: UInt64
    /// Larger than memory: GPU memory that keeps the experts used most; 0 when everything fits.
    var expertCache: UInt64
    /// Cluster: layers per device in llama.cpp's order (the helpers in `--rpc` order, then this Mac with the output layer).
    var tensorSplit: [Int]
    /// A model without experts that does not fit under the GPU limit: this many layers on the GPU, the rest on the processor. Nil: all.
    var gpuLayers: Int? = nil
    var threads: Int
    var contextSize: Int
    var warnings: [String]

    var cpuMoELayers: Int { hostExpertLayers.count }
    /// Everything that wants to stay in memory while the model runs (this Mac's part).
    var resident: UInt64 { dense + experts + overhead }
    var fitsInMemory: Bool { expertCache == 0 && resident + MemoryPlanner.osHeadroom <= physical }
    /// Expert bytes that are not kept in memory and come from the SSD when a token needs them.
    var streamedExperts: UInt64 { expertCache == 0 ? 0 : experts - min(experts, expertCache) }
}

enum MemoryPlanner {
    enum Fit { case fits, streams, tooBig }

    /// Before a download: does the model fit in this Mac's memory, or does it stream from the SSD? Only when even the
    /// dense weights and a small expert cache leave no room is it too big. (After the download `plan` decides from the files.)
    static func fit(_ model: ModelInfo, physical: UInt64) -> Fit {
        let memory = model.memory ?? model.totalSize
        if memory + minimumOverhead + osHeadroom <= physical { return .fits }
        // no experts to keep behind: what does not stay in memory is read back by macOS, whatever the size of this Mac
        if model.isPlain { return .streams }
        // streaming: the dense weights, the prompt buffers and an expert cache on the GPU, plus the staging reserve
        let dense = model.dense ?? memory / 10
        let buffers: UInt64 = isSmallMac(physical) ? 2_500_000_000 : 6_000_000_000
        let cache = isSmallMac(physical) ? smallestCacheOnSmallMac : minimumCache
        if dense + buffers + cache + streamingHeadroom(physical) + stagingReserve(physical) <= physical { return .streams }
        return .tooBig
    }

    /// KV for a small context, the compute buffers and the server: the least a model needs next to its weights.
    static let minimumOverhead: UInt64 = 2_900_000_000
    /// Below this much memory the reserves below, measured on larger Macs, would leave no expert cache at all. Those for a
    /// small Mac are estimates: not yet measured on a real Mac with 16 GB.
    static func isSmallMac(_ physical: UInt64) -> Bool { physical < 24 << 30 }
    static let smallestCacheOnSmallMac: UInt64 = 2_000_000_000
    /// Kept low on purpose: wired memory cannot be reclaimed, and a Mac without free memory locks up.
    static let largestCacheOnSmallMac: UInt64 = 3_000_000_000
    static let tinyMacContext = 16_384
    /// A model without experts pays for every token of context in all its layers: this much where memory is short.
    static let plainMinimumContext = 8_192
    /// The compute buffers of a model without experts: 7050 MiB in all at 8K, measured on the Windows version's test PC.
    static let plainBuffers: UInt64 = 1_000_000_000
    /// What a model that streams leaves for macOS and the apps.
    static func streamingHeadroom(_ physical: UInt64) -> UInt64 { isSmallMac(physical) ? 5_000_000_000 : osHeadroom }

    /// The smallest expert cache worth running with.
    static let minimumCache: UInt64 = 4_000_000_000
    /// Below this much memory a model that streams gives its room to the expert cache: a smaller context, no vision.
    static let roomyMemory: UInt64 = 64 << 30
    /// The context of a model that streams on a Mac with less than `roomyMemory`.
    static let smallMacContext = 32_768

    /// Does the whole model stay in memory on this Mac, with the smallest context?
    static func fitsWhole(index: GGUFIndex, system: SystemInfo) -> Bool {
        index.denseBytes + index.expertBytesPerLayer.values.reduce(0, +) + minimumOverhead + osHeadroom < system.physicalMemory
    }

    /// The largest context (a multiple of 4096) for this model on this Mac: what still lets a whole model stay in
    /// memory, and on a small Mac what leaves a model that streams its expert cache. Nil: the setting decides.
    static func contextRoom(index: GGUFIndex, system: SystemInfo, vision: Bool) -> Int? {
        guard fitsWhole(index: index, system: system) else {
            if index.isPlain { return plainMinimumContext }
            if isSmallMac(system.physicalMemory) { return tinyMacContext }
            return system.physicalMemory < roomyMemory ? smallMacContext : nil
        }
        let weights = index.denseBytes + index.expertBytesPerLayer.values.reduce(0, +)
        let fixed = weights + minimumOverhead + osHeadroom + (vision ? 1_500_000_000 : 0)
        guard fixed < system.physicalMemory, index.kvBytesPerToken > 0 else { return 0 }
        let tokens = Int((system.physicalMemory - fixed) / index.kvBytesPerToken)
        return max(index.isPlain ? plainMinimumContext : 4096, tokens / 4096 * 4096)
    }

    /// Left for macOS, the app and a browser; less than this and the system starts swapping.
    static let osHeadroom: UInt64 = 8_000_000_000
    /// Larger than memory: page cache for the experts on their way from the SSD to the GPU cache, and macOS's own wired
    /// memory. Measured on a 128 GB M3 Max: 115 GB wired in all ran steadily, 123 GB made macOS swap until writing
    /// dropped from 8 to 0.2 tokens/s. A smaller Mac reads fewer experts at a time, so this scales with its memory.
    static func stagingReserve(_ physical: UInt64) -> UInt64 {
        isSmallMac(physical) ? 2_000_000_000 : min(18_000_000_000, max(4_500_000_000, physical * 13 / 100))
    }

    /// An upper limit for the expert cache (UserDefaults "expertCacheMaxGB"), for a Mac that runs more next to the model.
    static var expertCacheLimit: UInt64? {
        let gb = UserDefaults.standard.double(forKey: "expertCacheMaxGB")
        return gb > 0 ? UInt64(gb * 1e9) : nil
    }

    /// What macOS and other apps may hold before the expert cache shrinks to make room (`inUse` below).
    static let othersAllowance: UInt64 = 16_000_000_000

    /// `helpers`: what each helper Mac's GPU can hold for the model, in `--rpc` order.
    /// `inUse`: memory macOS cannot hand out right now (measured just before the engine starts); when other apps hold
    /// more than `othersAllowance`, the expert cache gives up the difference.
    static func plan(index: GGUFIndex, system: SystemInfo, contextSize: Int, vision: Bool, gpuLimitOverride: UInt64? = nil,
                     helpers: [UInt64] = [], inUse: UInt64? = nil) -> MemoryPlan {
        let perLayer = index.expertBytesPerLayer
        let layers = max(index.layerCount, (perLayer.keys.max() ?? -1) + 1)
        // KV per model (DeepSeek's compressed attention ~0.7 GB per 128K, GLM ~2.6 GB); compute buffers ~2.5 GB at ubatch 1024
        let kv = index.kvBytesPerToken * UInt64(contextSize) + 400_000_000
        let overhead = kv + (index.isPlain ? plainBuffers : 2_500_000_000) + (vision ? 1_500_000_000 : 0)
        let physical = system.physicalMemory
        let gpuLimit = gpuLimitOverride ?? system.effectiveGPULimit
        let suggestedMB = Int((system.physicalMemory - osHeadroom) >> 20)

        // cluster: each helper takes as many whole layers as its GPU holds, this Mac keeps at least one
        let densePerLayer = index.denseBytes / UInt64(max(layers, 1))
        var split: [Int] = []
        var first = 0
        if !helpers.isEmpty {
            for budget in helpers {
                var n = 0
                var used: UInt64 = 0
                while first + n < layers - 1 {
                    let bytes = (perLayer[first + n] ?? 0) + densePerLayer
                    if used + bytes > budget { break }
                    used += bytes
                    n += 1
                }
                split.append(n)
                first += n
            }
            split.append(layers - first + 1)
        }
        let local = Array(first..<layers)
        let experts = local.reduce(UInt64(0)) { $0 + (perLayer[$1] ?? 0) }
        let dense = index.denseBytes - densePerLayer * UInt64(first)

        var hostLayers: [Int] = []
        var onGPU = experts
        var cache: UInt64 = 0
        var warnings: [String] = []
        var gpuLayers: Int?
        // no experts: where its layers go is all there is to decide, and an expert cache has nothing to hold
        if index.isPlain, dense + overhead > gpuLimit {
            let room = gpuLimit > overhead ? gpuLimit - overhead : 0
            gpuLayers = max(0, min(layers, Int(Double(layers) * Double(room) / Double(max(dense, 1)))))
        }
        let fits = index.isPlain || dense + experts + overhead + osHeadroom <= physical
        if fits {
            // the fewest layers with their experts in memory whose remainder fits on the GPU
            let budget = Int64(gpuLimit) - Int64(dense) - Int64(overhead)
            for il in local where Int64(onGPU) > budget && onGPU > 0 {
                onGPU -= perLayer[il] ?? 0
                hostLayers.append(il)
            }
            if helpers.isEmpty && gpuLimit + 4_000_000_000 < physical - osHeadroom && !hostLayers.isEmpty {
                warnings.append(L("De GPU mag nu \(gpuLimit.gb) vastzetten. Verhoog de limiet naar \((UInt64(suggestedMB) << 20).gb) met de knop hieronder, dan staan alle experts op de GPU."))
            }
        } else {
            // the compute buffers hold the experts of one layer while a prompt is read (ubatch 4096): measured 6.2 GB for
            // DeepSeek Q4 (7.2 GB of experts per layer), 3.8 GB for GLM Q4 (4.4 GB per layer)
            let promptCopy = 1_500_000_000 + (local.map { perLayer[$0] ?? 0 }.max() ?? 0) * 2 / 3
            let busy = (inUse ?? 0) > othersAllowance ? inUse! - othersAllowance : 0
            let reserved = streamingHeadroom(physical) + stagingReserve(physical) + min(busy, physical / 2)
            let wiredMax = min(gpuLimit, physical > reserved ? physical - reserved : 0)
            // instead of the generic 2.5 GB of compute buffers in `overhead`
            let buffers = Int64(overhead) - 2_500_000_000 + Int64(promptCopy)
            cache = min(UInt64(max(Int64(wiredMax) - Int64(dense) - buffers, 0)), expertCacheLimit ?? .max)
            if isSmallMac(physical) { cache = min(cache, largestCacheOnSmallMac) }
            hostLayers = local
            onGPU = 0
            warnings.append(L("Dit model is groter dan het geheugen. De experts die het gesprek het meest gebruikt (\(cache.gb)) blijven op de GPU; de rest (\((experts - min(experts, cache)).gb)) komt van de SSD als een woord ze nodig heeft."))
            if helpers.isEmpty && gpuLimit + 4_000_000_000 < physical - osHeadroom {
                let room = physical - streamingHeadroom(physical) - stagingReserve(physical)
                warnings.append(L("Verhoog de GPU-limiet naar \((UInt64(suggestedMB) << 20).gb) met de knop hieronder: dan krijgt de expert-cache \((min(room, UInt64(suggestedMB) << 20) - min(room, gpuLimit)).gb) meer."))
            }
        }
        if !index.isPlain && Int64(dense) + Int64(overhead) > Int64(gpuLimit) {
            warnings.append(L("Zelfs de vaste gewichten passen niet onder de GPU-limiet; verhoog de limiet of verklein de context."))
        }

        return MemoryPlan(
            physical: physical, gpuLimit: gpuLimit, suggestedWiredLimitMB: suggestedMB,
            dense: dense, experts: experts, engram: index.engramBytes, overhead: overhead,
            layers: layers, hostExpertLayers: hostLayers, gpuExperts: onGPU, cpuExperts: experts - onGPU,
            expertCache: cache, tensorSplit: split, gpuLayers: gpuLayers,
            threads: max(4, system.performanceCores), contextSize: contextSize, warnings: warnings)
    }
}
