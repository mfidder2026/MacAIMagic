import Foundation
import Compression

/// A .docx is a zip file. This reads stored and deflated entries and writes deflated ones, which is all Word needs.
enum Zip {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// A template comes from elsewhere: a small file must not unpack into all memory.
    private static let maxTotalSize = 4 << 30

    static func read(_ input: Data) throws -> [(name: String, data: Data)] {
        let data = Data(input)
        guard data.count >= 22 else { throw Failure(L("Dit is geen geldig Word-bestand.")) }
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        var end = data.count - 22
        let lowest = max(0, data.count - 65_557)
        while end >= lowest && u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= lowest else { throw Failure(L("Dit is geen geldig Word-bestand.")) }

        let count = u16(end + 10)
        var at = u32(end + 16)
        var total = 0
        var out: [(String, Data)] = []
        for _ in 0..<count {
            guard at + 46 <= data.count, u32(at) == 0x0201_4b50 else { throw Failure(L("Dit is geen geldig Word-bestand.")) }
            let flags = u16(at + 8), method = u16(at + 10), crc = u32(at + 16)
            let packed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32), local = u32(at + 42)
            guard flags & 1 == 0 else { throw Failure(L("Dit Word-bestand is beveiligd met een wachtwoord.")) }
            guard at + 46 + nameLength <= data.count, local + 30 <= data.count, u32(local) == 0x0403_4b50 else {
                throw Failure(L("Dit is geen geldig Word-bestand."))
            }
            let name = String(decoding: data[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + packed <= data.count else { throw Failure(L("Dit is geen geldig Word-bestand.")) }
            total += size
            guard total <= maxTotalSize else { throw Failure(L("Dit Word-bestand is te groot om uit te pakken.")) }
            let raw = data[start..<(start + packed)]
            let content: Data
            switch method {
            case 0: content = Data(raw)
            case 8: content = try inflate(raw, size: size)
            default: throw Failure(L("Dit Word-bestand gebruikt een onbekende compressie."))
            }
            guard crc32(content) == UInt32(crc) else { throw Failure(L("Dit Word-bestand is beschadigd.")) }
            if !name.hasSuffix("/") { out.append((name, content)) }
            at += 46 + nameLength + extra + comment
        }
        return out
    }

    static func write(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8 & 0xff)) }
        func put32(_ d: inout Data, _ v: Int) { put16(&d, v & 0xffff); put16(&d, v >> 16 & 0xffff) }

        for (name, content) in entries {
            let nameBytes = Data(name.utf8)
            let crc = Int(crc32(content))
            let packed = deflate(content)
            let body = packed ?? content
            let offset = out.count
            put32(&out, 0x0403_4b50)
            put16(&out, 20); put16(&out, 0x0800); put16(&out, packed == nil ? 0 : 8)
            put16(&out, 0); put16(&out, 0x21)                       // 1 January 1980: the bytes depend only on the content
            put32(&out, crc); put32(&out, body.count); put32(&out, content.count)
            put16(&out, nameBytes.count); put16(&out, 0)
            out.append(nameBytes)
            out.append(body)

            put32(&central, 0x0201_4b50)
            put16(&central, 20); put16(&central, 20); put16(&central, 0x0800); put16(&central, packed == nil ? 0 : 8)
            put16(&central, 0); put16(&central, 0x21)
            put32(&central, crc); put32(&central, body.count); put32(&central, content.count)
            put16(&central, nameBytes.count); put16(&central, 0); put16(&central, 0)
            put16(&central, 0); put16(&central, 0); put32(&central, 0); put32(&central, offset)
            central.append(nameBytes)
        }
        let start = out.count
        out.append(central)
        put32(&out, 0x0605_4b50)
        put16(&out, 0); put16(&out, 0)
        put16(&out, entries.count); put16(&out, entries.count)
        put32(&out, central.count); put32(&out, start)
        put16(&out, 0)
        return out
    }

    private static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            Data(raw).withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure(L("Dit Word-bestand is beschadigd.")) }
        return out
    }

    /// The deflated bytes, or nil when storing the entry is smaller.
    private static func deflate(_ content: Data) -> Data? {
        guard !content.isEmpty else { return nil }
        var out = Data(count: content.count + 1024)
        let capacity = out.count
        let written = out.withUnsafeMutableBytes { dst in
            content.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < content.count else { return nil }
        return out.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
