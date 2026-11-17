import Foundation
import Darwin

/// MacAIMagic Portable: the app runs from a USB drive and keeps everything there, in a folder `MacAIMagic-data` next to
/// the app: models, conversations, the engine's memory of them, the work folder, documents, pictures and the settings.
/// On the Mac it runs on it leaves no settings behind, and it starts offline: web search, the browser, Telegram, mail
/// and the cluster's network are off until the user turns them on. Meant for documents that must stay on the computer
/// they are on: nothing is installed and nothing goes to the internet.
///
/// The portable build is the same program with its own bundle id (app.fremen.macaimagic.portable, so it never shares
/// settings with an installed MacAIMagic) and `MacAIMagicPortable` in its Info.plist; scripts/make_app.sh PORTABLE=1.
enum Portable {
    static let isActive: Bool = Bundle.main.object(forInfoDictionaryKey: "MacAIMagicPortable") as? Bool == true

    /// The folder next to the app, made when missing; nil when not portable or when it cannot be written (a read-only
    /// drive): then the app falls back to its normal folder and says so (`problem`).
    static let dataRoot: URL? = {
        guard isActive else { return nil }
        let dir = folder(nextTo: original(Bundle.main.bundleURL))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".write-test")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return dir
        } catch {
            problem = "\(dir.path): \(error.localizedDescription)"
            return nil
        }
    }()

    /// Why the folder on the drive could not be used, for the user.
    nonisolated(unsafe) static var problem: String?

    static func folder(nextTo app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("MacAIMagic-data", isDirectory: true)
    }

    /// The name of the drive the data is on ("KINGSTON"), for the window.
    static var volumeName: String? {
        guard let dataRoot else { return nil }
        return (try? dataRoot.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    /// An app opened straight from a downloaded zip runs from a random read-only copy (Gatekeeper's translocation);
    /// its real place is asked from Security.framework, so the data folder lands next to the app on the drive.
    static func original(_ url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> UInt8
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let isT = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let orig = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isT, to: IsTranslocated.self)(url as CFURL, &translocated, nil) != 0, translocated,
              let real = unsafeBitCast(orig, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return real as URL
    }

    static var settingsFile: URL? { dataRoot?.appendingPathComponent("instellingen.plist") }

    /// The settings a portable start begins with: offline, and ports of its own beside an installed MacAIMagic.
    static func startDefaults(root: URL) -> [String: Any] {
        [
            "webSearch": false, "featureBrowser": false, "featureTelegram": false, "featureMail": false,
            "featureComputerUse": false, "heartbeat": false, "clusterAllowLAN": false,
            "port": 8090,
            "workspace": root.appendingPathComponent("Werkmap", isDirectory: true).path,
        ]
    }

    private nonisolated(unsafe) static var started = false

    /// Before anything reads a setting: the offline start values, then the settings saved on the drive.
    static func start() {
        guard isActive, !started else { return }
        started = true
        guard let root = dataRoot, let id = Bundle.main.bundleIdentifier else { return }
        let defaults = startDefaults(root: root)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Werkmap", isDirectory: true), withIntermediateDirectories: true)
        UserDefaults.standard.register(defaults: defaults)
        if let file = settingsFile, let saved = NSDictionary(contentsOf: file) as? [String: Any] {
            UserDefaults.standard.setPersistentDomain(saved, forName: id)
        }
    }

    /// At quit: the settings go to the drive, and the Mac keeps neither them nor the app's caches and window state.
    static func finish() {
        guard isActive, let root = dataRoot, let id = Bundle.main.bundleIdentifier else { return }
        let domain = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        if let file = settingsFile { (domain as NSDictionary).write(to: file, atomically: true) }
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()
        // AppKit still saves the window's frame after this, which writes the settings file again: a small process stays
        // behind, waits until the app is gone, and then removes the settings, caches and window state from this Mac
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let leftovers = ["Caches/\(id)", "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "WebKit/\(id)",
                         "Saved Application State/\(id).savedState", "Preferences/\(id).plist"]
            .map { "'" + library.appendingPathComponent($0).path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/sh")
        cleanup.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 1; "
            + "/usr/bin/defaults delete \(id) >/dev/null 2>&1; rm -rf \(leftovers.joined(separator: " "))"]
        try? cleanup.run()
        _ = root
    }
}
