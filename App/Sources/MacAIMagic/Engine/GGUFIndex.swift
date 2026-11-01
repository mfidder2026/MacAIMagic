import Foundation

/// Reads the tensor tables of a split GGUF (headers only) and groups the bytes the way the memory plan needs them:
/// dense weights, routed experts per layer, and the Engram tables that stay on the SSD.
struct GGUFIndex {
    struct Tensor { let name: String; let bytes: UInt64 }

    var tensors: [Tensor] = []
    var metadata: [String: Any] = [:]

    var expertBytesPerLayer: [Int: UInt64] {
        var out: [Int: UInt64] = [:]
        for t in tensors where t.name.contains("_exps.") {
            if let il = Self.layer(of: t.name) { out[il, default: 0] += t.bytes }
        }
        return out
    }
    var engramBytes: UInt64 {
        tensors.filter { $0.name.contains("engram_embd") || $0.name.hasPrefix("per_layer_token_embd") }
            .reduce(0) { $0 + $1.bytes }
    }
    var denseBytes: UInt64 {
        tensors.filter { !$0.name.contains("_exps.") && !$0.name.contains("engram_embd") && !$0.name.hasPrefix("per_layer_token_embd") }
            .reduce(0) { $0 + $1.bytes }
    }
    /// <arch>.block_count, whatever the architecture is called
    var layerCount: Int {
        for (k, v) in metadata where k.hasSuffix(".block_count") {
            if let n = v as? UInt32 { return Int(n) }
            if let n = v as? UInt64 { return Int(n) }
        }
        return (expertBytesPerLayer.keys.max() ?? -1) + 1
    }
    var architecture: String { metadata["general.architecture"] as? String ?? "" }
    /// <arch>.context_length: the longest context the model was made for (0 = unknown)
    var contextLength: Int {
        for (k, v) in metadata where k.hasSuffix(".context_length") && !k.contains("original") {
            if let n = v as? UInt32 { return Int(n) }
            if let n = v as? UInt64 { return Int(n) }
        }
        return 0
    }
    /// KV cache per token of context: measured for DeepSeek (compressed attention) and GLM, from the heads for Qwen
    var kvBytesPerToken: UInt64 {
        switch architecture {
        case "deepseek41", "deepseek4": return 5_600
        case "glm5-next": return 20_000
        case "qwen4exp": return 36_000
        default: return 32_000
        }
    }

    static func layer(of name: String) -> Int? {
        let parts = name.split(separator: ".")
        guard parts.count > 2, parts[0] == "blk" else { return nil }
        return Int(parts[1])
    }

    /// Index every shard that is on disk; a shard still downloading is read as far as its header goes.
    /// `sizes` are the shards' full sizes, so a partly downloaded shard still gives its last tensor's true size.
    static func load(shards: [URL], sizes: [UInt64]) throws -> GGUFIndex {
        var index = GGUFIndex()
        for (url, size) in zip(shards, sizes) {
            let shard = try readShard(url, fileSize: size)
            index.tensors += shard.tensors
            index.metadata.merge(shard.metadata) { a, _ in a }
        }
        return index
    }

    private static func readShard(_ url: URL, fileSize declared: UInt64) throws -> GGUFIndex {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var r = Reader(fh: fh)
        guard try r.bytes(4) == Data("GGUF".utf8) else { throw GGUFError.notGGUF(url.lastPathComponent) }
        _ = try r.u32()
        let nTensors = try r.u64(), nKV = try r.u64()
        var meta: [String: Any] = [:]
        for _ in 0..<nKV {
            let key = try r.string()
            let type = try r.u32()
            meta[key] = try r.value(type)
        }
        var infos: [(String, UInt64)] = []
        for _ in 0..<nTensors {
            let name = try r.string()
            let nd = try r.u32()
            for _ in 0..<nd { _ = try r.u64() }
            _ = try r.u32()  // type
            infos.append((name, try r.u64()))
        }
        // tensor sizes from consecutive offsets: no per-type block table to keep in sync with ggml
        let align = UInt64((meta["general.alignment"] as? UInt32) ?? 32)
        let dataStart = (r.offset + align - 1) / align * align
        let sorted = infos.sorted { $0.1 < $1.1 }
        var out = GGUFIndex(tensors: [], metadata: meta)
        for (i, info) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].1 : (declared > dataStart ? declared - dataStart : info.1)
            out.tensors.append(Tensor(name: info.0, bytes: end - info.1))
        }
        return out
    }

    enum GGUFError: LocalizedError {
        case notGGUF(String), truncated
        var errorDescription: String? {
            switch self {
            case .notGGUF(let f): return L("\(f) is geen GGUF-bestand")
            case .truncated: return "GGUF-header is onvolledig"
            }
        }
    }

    private struct Reader {
        let fh: FileHandle
        var buffer = Data()
        var base: UInt64 = 0
        var pos = 0
        var offset: UInt64 { base + UInt64(pos) }

        mutating func bytes(_ n: Int) throws -> Data {
            while pos + n > buffer.count {
                try fh.seek(toOffset: base + UInt64(buffer.count))
                guard let chunk = try fh.read(upToCount: max(n, 4 << 20)), !chunk.isEmpty else { throw GGUFError.truncated }
                buffer.append(chunk)
            }
            let d = buffer.subdata(in: pos..<pos + n)
            pos += n
            return d
        }
        mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let d = try bytes(MemoryLayout<T>.size)
            return d.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        mutating func u32() throws -> UInt32 { try int(UInt32.self) }
        mutating func u64() throws -> UInt64 { try int(UInt64.self) }
        mutating func string() throws -> String {
            String(decoding: try bytes(Int(try u64())), as: UTF8.self)
        }
        mutating func value(_ type: UInt32) throws -> Any {
            switch type {
            case 0, 1, 7: return try bytes(1)[0]
            case 2, 3: return try int(UInt16.self)
            case 4: return try u32()
            case 5: return try int(Int32.self)
            case 6: return Float(bitPattern: try u32())
            case 8: return try string()
            case 9:
                let et = try u32(), n = try u64()
                // big arrays (vocab, token maps) are skipped, not kept
                if n > 4096 { for _ in 0..<n { _ = try value(et) }; return n }
                return try (0..<n).map { _ in try value(et) }
            case 10: return try u64()
            case 11: return try int(Int64.self)
            case 12: return Double(bitPattern: try u64())
            default: throw GGUFError.truncated
            }
        }
    }
}
