import Foundation
import Metal

/// What MacAIMagic needs on this Mac, checked at every start. What the app can put right itself it does; what needs
/// the user (a password, a download of 100+ GB, Apple's installer) it offers with one button.
@MainActor
final class SystemCheck: ObservableObject {
    enum State { case ok, fixed, todo, optional, failed }
    enum Action { case openModels, openCluster, raiseGPULimit(Int), installDeveloperTools }

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let state: State
        var action: (label: String, action: Action)? = nil
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false

    /// Something keeps the app from working: the start opens the check.
    var needsAttention: Bool { items.contains { $0.state == .failed } }

    func run(app: AppState) async {
        running = true
        app.refreshSystem()
        app.models.refresh()
        var list = [macItem(app.system), await engineItem(), downloadItem()]
        list += modelItems(app)
        if let gpu = gpuItem(app) { list.append(gpu) }
        list.append(await developerToolsItem())
        items = list
        running = false
    }

    // MARK: - the checks

    private func macItem(_ s: SystemInfo) -> Item {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        guard MTLCreateSystemDefaultDevice() != nil else {
            return Item(id: "mac", title: L("Deze Mac"), detail: L("Geen Metal-GPU gevonden: de engine kan hier niet rekenen."), state: .failed)
        }
        return Item(id: "mac", title: L("Deze Mac"), detail: "\(s.chip) · \(s.physicalMemory >> 30) GB · macOS \(os)", state: .ok)
    }

    private func engineItem() async -> Item {
        let title = L("Engine")
        guard let bin = Paths.engineBinary("llama-server") else {
            return Item(id: "engine", title: title, detail: L("De engine ontbreekt in de app. Installeer MacAIMagic opnieuw."), state: .failed)
        }
        if let v = await Self.version(bin) { return Item(id: "engine", title: title, detail: v, state: .ok) }
        // a downloaded copy keeps Apple's quarantine mark, and macOS may stop the engine inside it: the user opened
        // the app, so the mark comes off the whole app, and the engine gets another try
        if Self.removeQuarantine(), let v = await Self.version(bin) {
            return Item(id: "engine", title: title, detail: L("macOS hield de engine tegen; dat is opgeheven.") + " " + v, state: .fixed)
        }
        let moved = Bundle.main.bundlePath.contains("/AppTranslocation/")
            ? L("Zet MacAIMagic in de map Programma's en open hem daar opnieuw.") : L("Installeer MacAIMagic opnieuw.")
        return Item(id: "engine", title: title, detail: L("De engine start niet op deze Mac.") + " " + moved, state: .failed)
    }

    private func downloadItem() -> Item {
        let title = L("Downloaden")
        let missing = ["/usr/bin/curl", "/usr/bin/shasum", "/usr/bin/osascript"].filter { !FileManager.default.isExecutableFile(atPath: $0) }
        if Paths.script("download_model.sh") == nil || !missing.isEmpty {
            let what = (missing.map { ($0 as NSString).lastPathComponent } + (Paths.script("download_model.sh") == nil ? ["download_model.sh"] : []))
            return Item(id: "download", title: title, detail: L("Ontbreekt: \(what.joined(separator: ", ")). Installeer MacAIMagic opnieuw."), state: .failed)
        }
        return Item(id: "download", title: title, detail: L("Alles aanwezig om modellen te downloaden en te controleren."), state: .ok)
    }

    private func modelItems(_ app: AppState) -> [Item] {
        let models = app.models
        let ready = models.catalog.models.filter { models.status($0.id).isComplete }
        if !ready.isEmpty {
            let free = Item(id: "disk", title: L("Schijfruimte"), detail: L("\(app.system.freeDisk.gbShort) vrij"), state: .ok)
            return [Item(id: "model", title: L("Model"), detail: ready.map(\.name).joined(separator: ", "), state: .ok), free]
        }
        // no model fits in this Mac's memory: it is best a helper in a cluster, which needs no model of its own
        guard let best = Self.recommended(models.catalog.models, physical: app.system.physicalMemory) else {
            return [Item(id: "model", title: L("Model"),
                         detail: L("Geen van de modellen past in de \(app.system.physicalMemory >> 30) GB van deze Mac. Gebruik hem als helper in een cluster, daarvoor is geen model nodig."),
                         state: .optional, action: (L("Naar Cluster"), .openCluster)),
                    Item(id: "disk", title: L("Schijfruimte"), detail: L("\(app.system.freeDisk.gbShort) vrij"), state: .ok)]
        }
        let downloading = models.downloading.contains(best.id)
        let model = Item(id: "model", title: L("Model"),
                         detail: downloading ? L("\(best.name) wordt gedownload.")
                             : L("Nog geen model. Aanbevolen voor deze Mac met \(app.system.physicalMemory >> 30) GB: \(best.name) (\(best.totalSize.gbShort)), dat helemaal in het geheugen past.")
                                + (models.catalog.models.contains { MemoryPlanner.fit($0, physical: app.system.physicalMemory) == .streams }
                                   ? " " + L("De grotere modellen kun je ook gebruiken: die streamen van de SSD en zijn trager.") : ""),
                         state: .todo, action: downloading ? nil : (L("Naar Modellen"), .openModels))
        let enough = app.system.freeDisk > best.totalSize + (5 << 30)
        let disk = Item(id: "disk", title: L("Schijfruimte"),
                        detail: enough ? L("\(app.system.freeDisk.gbShort) vrij, genoeg voor \(best.shortName).")
                            : L("\(app.system.freeDisk.gbShort) vrij; \(best.shortName) heeft \(best.totalSize.gbShort) nodig. Maak ruimte vrij of kies onder Modellen een map op een andere schijf."),
                        state: enough ? .ok : .failed)
        return [model, disk]
    }

    private func gpuItem(_ app: AppState) -> Item? {
        guard let plan = app.plan, app.system.wiredLimitMB < plan.suggestedWiredLimitMB - 1024 else { return nil }
        let target = (UInt64(plan.suggestedWiredLimitMB) << 20).gb
        return Item(id: "gpu", title: L("GPU-limiet"),
                    detail: L("Met een limiet van \(target) houdt de GPU meer van het model in het snelle geheugen. Vraagt je wachtwoord; geldt tot de Mac herstart."),
                    state: .optional, action: (L("Verhoog"), .raiseGPULimit(plan.suggestedWiredLimitMB)))
    }

    private func developerToolsItem() async -> Item {
        let title = L("Ontwikkeltools van Apple")
        if await Self.run("/usr/bin/xcode-select", ["-p"])?.status == 0 {
            return Item(id: "devtools", title: title, detail: L("Aanwezig: het model kan in de werkmap Python, git en make gebruiken."), state: .ok)
        }
        return Item(id: "devtools", title: title,
                    detail: L("Niet nodig voor de app zelf. Wel als het model in de werkmap Python, git of make wil gebruiken."),
                    state: .optional, action: (L("Installeer"), .installDeveloperTools))
    }

    // MARK: - actions

    func perform(_ action: Action, app: AppState, open: (Pane) -> Void) {
        switch action {
        case .openModels:
            if let best = Self.recommended(app.models.catalog.models, physical: app.system.physicalMemory) { app.selectedModelID = best.id }
            open(.models)
        case .openCluster:
            open(.cluster)
        case .raiseGPULimit(let mb):
            app.raiseWiredLimit(mb: mb)
            Task { await run(app: app) }
        case .installDeveloperTools:
            // Apple's own installer window; the check notices the tools at its next run
            Task { _ = await Self.run("/usr/bin/xcode-select", ["--install"]) }
        }
    }

    // MARK: - helpers

    /// Are Apple's developer tools here? Without them python3, git and make only ask to install them.
    nonisolated static var hasDeveloperTools: Bool {
        FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/clang")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
    }

    /// The first model in the catalog (largest and best first) that fits whole in this Mac's memory.
    nonisolated static func recommended(_ models: [ModelInfo], physical: UInt64) -> ModelInfo? {
        models.first { MemoryPlanner.fit($0, physical: physical) == .fits }
    }

    /// "llama.cpp <version>" when the engine runs, nil when it does not start.
    private static func version(_ bin: URL) async -> String? {
        guard let r = await run(bin.path, ["--version"]), r.status == 0 else { return nil }
        let line = r.output.split(separator: "\n").first { $0.hasPrefix("version") }.map(String.init) ?? ""
        return "llama.cpp " + line.replacingOccurrences(of: "version: ", with: "")
    }

    /// Removes the quarantine mark from the app when it has one; true when it did.
    private static func removeQuarantine() -> Bool {
        let app = Bundle.main.bundlePath
        guard getxattr(app, "com.apple.quarantine", nil, 0, 0, 0) >= 0,
              FileManager.default.isWritableFile(atPath: app) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", app]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Runs a tool off the main thread and gives its exit status and output; stops it after `timeout` seconds.
    nonisolated static func run(_ path: String, _ args: [String], timeout: Double = 20) async -> (status: Int32, output: String)? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if p.isRunning { p.terminate(); return nil }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (p.terminationStatus, out)
        }.value
    }
}
