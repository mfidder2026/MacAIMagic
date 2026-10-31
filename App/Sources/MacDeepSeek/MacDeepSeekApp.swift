import SwiftUI

@main
struct MacDeepSeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("MacDeepSeek") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(app.models)
                .environmentObject(app.store)
                .environmentObject(app.chat)
                .environmentObject(Settings.shared)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.accent)
                .onAppear {
                    delegate.app = app
                    if Settings.shared.autoStart && app.canStart { app.startEngine() }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nieuw gesprek") { app.store.newConversation() }.keyboardShortcut("n")
            }
        }

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(Settings.shared)
        }
    }
}

/// Stops the engine with the app, so 115 GB of wired memory is never left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.store.save()
            app?.engine.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Theme {
    static let accent = Color(red: 0.30, green: 0.42, blue: 1.0)      // DeepSeek blue
    static let userBubble = Color(red: 0.30, green: 0.42, blue: 1.0).opacity(0.14)
    static let card = Color(nsColor: .controlBackgroundColor)
}
