import SwiftUI
import AppKit

/// Asks the window to show a pane (from the menu bar, or a notification).
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()
    @Published var pane: Pane?
}

/// The menu bar item while tasks or a heartbeat run in the background: what is going on, and the way back in.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var tasks: TaskStore
    @EnvironmentObject var settings: Settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.state.isRunning ? L("Model geladen: \(engine.model?.name ?? "")") : L("Model niet geladen"))
        if !app.taskRuns.isEmpty {
            Text(L("Taken bezig: \(app.taskRuns.count)"))
        } else if chat.busy {
            Text(L("Bezig met een gesprek"))
        }
        if let next = tasks.tasks.filter({ $0.enabled && $0.nextRun != nil }).min(by: { $0.nextRun! < $1.nextRun! }) {
            Text(L("Volgende taak: \(next.title), \(next.nextRun!.formatted(date: .abbreviated, time: .shortened))"))
        }
        if settings.heartbeat, let status = app.heartbeatStatus { Text(status) }
        Divider()
        Button(L("Open MacAIMagic")) { show(nil) }
        Button(L("Taken")) { show(.tasks) }
        if settings.heartbeat { Button(L("Nu controleren")) { Task { await app.heartbeat(forced: true) } } }
        if chat.busy { Button(L("Alles stoppen")) { chat.stopAll() } }
        Divider()
        Button(L("Stop MacAIMagic")) { NSApp.terminate(nil) }
    }

    private func show(_ pane: Pane?) {
        if MainWindow.open == nil { MainWindow.open = openWindow }
        MainWindow.show()
        if let pane { AppNavigator.shared.pane = pane }
    }
}

/// The app's one window: shown again from the Dock, from `open`, and from the menu bar.
@MainActor
enum MainWindow {
    /// SwiftUI's action that opens a new main window; taken from the first window's environment.
    static var open: OpenWindowAction?

    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
    }

    /// Keeps the open action of the window it sits in.
    struct Capture: View {
        @Environment(\.openWindow) private var openWindow
        var body: some View { Color.clear.onAppear { MainWindow.open = openWindow } }
    }
}
