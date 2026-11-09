import Foundation

/// How far loading or unloading a model is, for the gauge. The engine says little while it maps a model of 100 GB (a dot
/// now and then), so the time it took last time counts too: the gauge runs on the clock, and on what the engine reports
/// when that is further. The first time the size gives a guess. (Taken over from WinAIMagic, with the Mac's own numbers.)
enum LoadClock {
    /// Reading speed for the first guess. Measured on the M3 Max: DeepSeek-V4.1-Flash Compact (115 GB) loaded in 57 s with
    /// its files in the page cache; from a cold SSD it takes longer, so the guess is a little slower than that.
    static let bytesPerSecond = 1.5e9
    /// Unloading gives the memory back: a few seconds, longer for a model of 100 GB.
    static func firstUnload(_ bytes: UInt64) -> TimeInterval { 3 + Double(bytes) / 40e9 }
    static func firstLoad(_ bytes: UInt64) -> TimeInterval { 3 + Double(bytes) / bytesPerSecond }

    /// 0..0.99: never full before the engine answers. Past the expected time it creeps on instead of standing still.
    static func fraction(reported: Double, elapsed: TimeInterval, expected: TimeInterval) -> Double {
        var byTime = expected <= 0 ? 0 : max(0, elapsed) / expected
        if byTime > 0.9 { byTime = 0.9 + 0.09 * (1 - exp(-(byTime - 0.9) * 3)) }
        return min(0.99, max(0, max(reported, byTime)))
    }

    /// Seconds still to go, or nil when it is past the expected time (then the gauge only says it is busy).
    static func remaining(elapsed: TimeInterval, expected: TimeInterval) -> Int? {
        let left = expected - elapsed
        return left >= 1 ? Int(left.rounded(.up)) : nil
    }

    static var file: URL { Paths.appSupport.appendingPathComponent("load-times.json") }
    private static let lock = NSLock()

    /// The time remembered for this key ("load:model-id", "unload:model-id"), or the guess.
    static func expected(_ key: String, guess: TimeInterval, file: URL = file) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let t = read(file)[key] ?? 0
        return t > 0 ? t : guess
    }

    /// Remembers how long it took; the newest time weighs most (the first load after a restart reads from the SSD, a
    /// later one from the page cache).
    static func record(_ key: String, took: TimeInterval, file: URL = file) {
        guard took > 0, took < 7200 else { return }
        lock.lock(); defer { lock.unlock() }
        var all = read(file)
        all[key] = all[key].map { $0 > 0 ? 0.6 * took + 0.4 * $0 : took } ?? took
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }

    private static func read(_ file: URL) -> [String: Double] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }
}
