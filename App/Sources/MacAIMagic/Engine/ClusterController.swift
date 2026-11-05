import Foundation
import IOKit.pwr_mgt

/// Several Macs as one memory. A helper Mac runs llama.cpp's RPC server (ggml-rpc-server) on its GPU and announces
/// itself with Bonjour; the main Mac finds the helpers, and its engine spreads the model's layers over its own GPU and
/// theirs (`--rpc`), in proportion to the memory each reports. Per token only a layer's output travels between the
/// Macs (a few tens of KB), so a Thunderbolt cable is plenty.
@MainActor
final class ClusterController: NSObject, ObservableObject {
    static let serviceType = "_mdsrpc._tcp."
    static let defaultPort = 50052

    struct Helper: Identifiable, Hashable {
        var id: String { "\(host):\(port)" }
        var name: String
        var chip: String
        var memoryGB: Double        // unified memory
        var gpuGB: Double           // what its GPU may keep resident
        var host: String
        var port: Int
        var manual = false
        /// A helper added by hand that did not answer: it stays out of the next start, the engine would not start with it.
        var unreachable = false
        var viaThunderbolt: Bool { host.hasPrefix("169.254.") }
    }

    enum Role: String { case main, helper }

    @Published private(set) var helpers: [Helper] = []
    @Published var selected: Set<String> {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "clusterSelected") }
    }
    @Published private(set) var helperRunning = false
    @Published private(set) var helperAddress = ""
    @Published private(set) var helperLog: [String] = []

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var published: NetService?
    private var server: Process?
    private var sleepAssertion: IOPMAssertionID = 0

    override init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "clusterSelected") ?? [])
        super.init()
        for manual in UserDefaults.standard.stringArray(forKey: "clusterManual") ?? [] { addManual(manual, save: false) }
        browse()
    }

    var role: Role { Role(rawValue: Settings.shared.clusterRole) ?? .main }

    /// The helpers that take part in the next engine start.
    var active: [Helper] { role == .main ? helpers.filter { selected.contains($0.id) && !$0.unreachable } : [] }

    /// Extra GPU memory the active helpers bring (minus room for their own macOS and buffers).
    var extraGPU: UInt64 { UInt64(active.reduce(0) { $0 + max($1.gpuGB - 3, 0) } * 1e9) }
    /// What each active helper's GPU can hold for the model, in `--rpc` order (unknown for a helper added by hand: 0).
    var helperBudgets: [UInt64] { budgetOverride ?? active.map { UInt64(max($0.gpuGB - 3, 0) * 1e9) } }
    /// Tests: a helper on this same Mac shares its memory, so the test says what the helper may take.
    var budgetOverride: [UInt64]?
    var rpcArgument: String? { active.isEmpty ? nil : active.map { "\($0.host):\($0.port)" }.joined(separator: ",") }

    // MARK: - main Mac: find helpers

    private func browse() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        browser = b
    }

    func addManual(_ text: String, save: Bool = true) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return }
        let port = parts.count > 1 ? Int(parts[1]) ?? Self.defaultPort : Self.defaultPort
        let h = Helper(name: host, chip: "?", memoryGB: 0, gpuGB: 0, host: host, port: port, manual: true)
        if !helpers.contains(where: { $0.id == h.id }) { helpers.append(h) }
        selected.insert(h.id)
        if save { saveManual() }
        probe(h)
    }

    /// Tests: what a helper added by hand reports, in MiB; nil when it cannot be reached.
    var probeOverride: ((String) -> Int64?)?

    /// Ask the helpers added by hand again: one may have been turned on since.
    func recheckManual() { for h in helpers where h.manual { probe(h) } }

    /// A helper added by hand announces nothing: ask it what it can hold, as the engine would see it.
    private func probe(_ h: Helper) {
        let override = probeOverride
        let binary = Paths.engineBinary("llama-server")
        guard override != nil || binary != nil else { return }
        Task { [weak self] in
            let mib: Int64?
            if let override { mib = override(h.id) }
            else if let r = await SystemCheck.run(binary!.path, ["--rpc", h.id, "--list-devices"]) { mib = Self.helperMemory(r.output) }
            else { mib = nil }
            guard let self, let i = self.helpers.firstIndex(where: { $0.id == h.id }) else { return }
            self.helpers[i].gpuGB = Double(mib ?? 0) * 1_048_576 / 1e9
            self.helpers[i].unreachable = mib == nil
        }
    }

    /// The MiB of the first RPC device in --list-devices: "RPC0: 10.0.0.2:50052 (16310 MiB, 15172 MiB free)".
    nonisolated static func helperMemory(_ output: String) -> Int64? {
        guard let match = output.range(of: #"RPC\d*:\s+\S+\s+\(\d+ MiB"#, options: .regularExpression) else { return nil }
        let text = output[match]
        guard let open = text.lastIndex(of: "(") else { return nil }
        return Int64(text[text.index(after: open)...].prefix { $0.isNumber })
    }

    func remove(_ helper: Helper) {
        helpers.removeAll { $0.id == helper.id }
        selected.remove(helper.id)
        saveManual()
    }

    private func saveManual() {
        UserDefaults.standard.set(helpers.filter(\.manual).map(\.id), forKey: "clusterManual")
    }

    fileprivate func found(_ service: NetService) {
        guard let txt = service.txtRecordData() else { return }
        let dict = NetService.dictionary(fromTXTRecord: txt).mapValues { String(decoding: $0, as: UTF8.self) }
        guard let host = dict["ip"], !host.isEmpty else { return }
        let h = Helper(name: service.name, chip: dict["chip"] ?? "?", memoryGB: Double(dict["mem"] ?? "") ?? 0,
                       gpuGB: Double(dict["gpu"] ?? "") ?? 0, host: host, port: service.port > 0 ? service.port : Self.defaultPort)
        helpers.removeAll { $0.id == h.id }
        helpers.append(h)
        helpers.sort { $0.name < $1.name }
    }

    fileprivate func lost(_ service: NetService) {
        helpers.removeAll { !$0.manual && $0.name == service.name }
    }

    // MARK: - helper Mac: serve this GPU

    /// IPv4 addresses of this Mac by interface: the Thunderbolt bridge first (bridge*), then the rest.
    static func addresses() -> [(interface: String, ip: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append((name, String(cString: host)))
            }
        }
        return result.sorted { ($0.0.hasPrefix("bridge") ? 0 : 1, $0.0) < ($1.0.hasPrefix("bridge") ? 0 : 1, $1.0) }
    }

    /// The address the helper listens on: the Thunderbolt bridge unless the user allows the local network.
    static func bindAddress() -> String? {
        let all = addresses()
        if let tb = all.first(where: { $0.interface.hasPrefix("bridge") }) { return tb.ip }
        return Settings.shared.clusterAllowLAN ? all.first?.ip : nil
    }

    func startHelper(bind override: String? = nil) {
        guard server == nil else { return }
        guard let bin = Paths.engineBinary("ggml-rpc-server") else {
            helperLog = [L("ggml-rpc-server niet gevonden: bouw de engine opnieuw (scripts/build_engine.sh).")]
            return
        }
        guard let ip = override ?? Self.bindAddress() else {
            helperLog = [L("Geen Thunderbolt-verbinding gevonden. Sluit de Macs aan met een Thunderbolt-kabel (Systeeminstellingen → Netwerk → Thunderbolt-brug), of sta het lokale netwerk toe.")]
            return
        }
        let p = Process()
        p.executableURL = bin
        // -c: keep the model parts this helper receives on its own disk, so the next start does not send them again
        p.arguments = ["-H", ip, "-p", String(Self.defaultPort), "-d", "MTL0", "-c"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let lines = String(decoding: h.availableData, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.contains("ggml_metal_library") }
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                self?.helperLog.append(contentsOf: lines)
                if let n = self?.helperLog.count, n > 200 { self?.helperLog.removeFirst(n - 200) }
            }
        }
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.helperStopped() } }
        do { try p.run() } catch {
            helperLog = [L("Kon de helper niet starten: \(error.localizedDescription)")]
            return
        }
        server = p
        helperRunning = true
        helperAddress = "\(ip):\(Self.defaultPort)"
        preventSleep(true)
        publish(ip: ip)
    }

    func stopHelper() {
        server?.interrupt()
        let p = server
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p?.isRunning == true { p?.terminate() } }
    }

    /// Stop and start again, so the helper announces what it can hold now.
    func restartHelper() {
        guard let p = server else { return }
        let restart: () -> Void = { [weak self] in Task { @MainActor in self?.startHelper() } }
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.helperStopped(); restart() } }
        stopHelper()
    }

    private func helperStopped() {
        server = nil
        helperRunning = false
        published?.stop()
        published = nil
        preventSleep(false)
    }

    private func publish(ip: String) {
        let system = SystemInfo.current()
        let name = Host.current().localizedName ?? L("Mac")
        let s = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(Self.defaultPort))
        let txt: [String: Data] = [
            "ip": Data(ip.utf8),
            "chip": Data(system.chip.utf8),
            "mem": Data(String(format: "%.0f", Double(system.physicalMemory) / 1e9).utf8),
            // the raised GPU limit when there is one, else Metal's recommendation
            "gpu": Data(String(format: "%.0f", Double(system.effectiveGPULimit) / 1e9).utf8),
        ]
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.publish()
        published = s
    }

    private func preventSleep(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "MacAIMagic: helper in het cluster" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}

extension ClusterController: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { lost(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            found(sender)
            resolving.removeAll { $0 === sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        MainActor.assumeIsolated { found(sender) }
    }
}
