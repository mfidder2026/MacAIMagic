import SwiftUI

@main
struct MacAIMagicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()
    @ObservedObject private var settings = Settings.shared

    var body: some Scene {
        WindowGroup("MacAIMagic", id: "main") {
            RootView()
                // a new language redraws every view, and dates follow it
                .id(settings.language)
                .environment(\.locale, Locale(identifier: settings.language))
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(app.models)
                .environmentObject(app.store)
                .environmentObject(app.chat)
                .environmentObject(app.metrics)
                .environmentObject(app.bench)
                .environmentObject(app.cluster)
                .environmentObject(app.check)
                .environmentObject(app.documents)
                .environmentObject(app.images)
                .environmentObject(app.tasks)
                .environmentObject(Settings.shared)
                .background(MainWindow.Capture())
                .frame(minWidth: 1000, minHeight: 680)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.app = app
                    app.startTasks()
                    NSApp.setActivationPolicy(.regular)
                    if Settings.shared.autoStart && app.canStart { app.startEngine() }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Nieuw gesprek")) { app.store.newConversation() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .help) {
                Button(L("MacAIMagic-hulp")) { HelpCenter.shared.open("start") }.keyboardShortcut("?", modifiers: .command)
                Button(L("Problemen oplossen")) { HelpCenter.shared.open("troubleshooting") }
                Button(L("Sneltoetsen")) { HelpCenter.shared.open("shortcuts") }
            }
        }

        // while tasks or a heartbeat can run with the window closed (Instellingen → Taken)
        MenuBarExtra(isInserted: Binding(get: { settings.stayInMenuBar && app.hasBackgroundWork }, set: { _ in })) {
            MenuBarView()
                .environment(\.locale, Locale(identifier: settings.language))
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(app.chat)
                .environmentObject(app.tasks)
                .environmentObject(Settings.shared)
        } label: {
            Image(systemName: app.taskRuns.isEmpty ? "sparkles" : "sparkles.rectangle.stack")
        }

        SwiftUI.Settings {
            SettingsView()
                .id(settings.language)
                .environment(\.locale, Locale(identifier: settings.language))
                .environmentObject(app)
                .environmentObject(Settings.shared)
        }
    }
}

/// Stops the engine with the app, so 115 GB of wired memory is never left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineOrphans.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.store.save()
            app?.engine.stopForQuit()
            app?.documentEngines.fast.stop()
            app?.cluster.stopHelper()
            app?.documents.save()
            MCPManager.shared.stopAll()
        }
    }

    /// The window closed: the app stops, unless tasks or a heartbeat should go on; then it stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            guard let app, Settings.shared.stayInMenuBar, app.hasBackgroundWork else { return true }
            app.windowClosed()
            return false
        }
    }

    /// A click on the Dock icon (or opening the app again) with no window: it comes back. Returning true alone did not
    /// bring it back once the app had stayed in the menu bar (seen 2026-11-09): the window is opened here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated { MainWindow.show() }
        return false
    }
}
