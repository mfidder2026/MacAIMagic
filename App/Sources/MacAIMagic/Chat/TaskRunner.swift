import AppKit

/// Runs the scheduled tasks: on time, with the model started when needed and stopped again afterwards, each run a
/// conversation of its own, and a notification when it is done or needs the user.
extension AppState {
    /// Called once the window is there: the timer, waking from sleep, and the chat client's signals.
    func startTasks() {
        guard taskTimer == nil else { return }
        Notifier.shared.setUp()
        chat.onFinished = { [weak self] id in self?.runFinished(id) }
        chat.onSend = { [weak self] id in
            // the user used the model: it is theirs now, a task must not stop it
            if self?.taskRuns[id] == nil { self?.modelStartedByTasks = false }
        }
        chat.onApproval = { [weak self] a in self?.approvalNeeded(a) }
        taskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTasks() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tickTasks() }
        }
        tickTasks()
    }

    func tickTasks(now: Date = Date()) {
        for task in tasks.takeDue(now: now) {
            Task { await runTask(task) }
        }
    }

    /// One run of a task: a new conversation with its prompt. Nil when the model could not start.
    @discardableResult
    func runTask(_ task: ScheduledTask) async -> Conversation.ID? {
        guard await ensureModel() else {
            Notifier.shared.post(title: L("Taak niet uitgevoerd: \(task.title)"),
                                 body: L("Het model kon niet starten. Kijk in MacAIMagic bij Modellen of Engine."), conversation: nil)
            return nil
        }
        var c = Conversation(title: "⏱ " + task.title + " · " + Date().formatted(date: .abbreviated, time: .shortened))
        c.workspace = task.workspace
        c.task = task.id
        store.conversations.insert(c, at: 0)
        taskRuns[c.id] = task.id
        tasks.ran(task.id, conversation: c.id)
        if taskActivity == nil {
            // a task in progress keeps the Mac awake (not the screen)
            taskActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "MacAIMagic runs a task")
        }
        chat.send(text: task.prompt, attachments: [], in: c.id, store: store, baseURL: engine.baseURL)
        return c.id
    }

    /// The model is loaded, or loads now; false when it cannot (not downloaded, an image being made, start failed).
    func ensureModel() async -> Bool {
        if engine.state.isRunning { return true }
        if case .starting = engine.state {} else {
            guard canStart else { return false }
            startEngine()
            modelStartedByTasks = true
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 1800 {
            switch engine.state {
            case .running: return true
            case .failed: return false
            case .stopped where Date().timeIntervalSince(start) > 10: return false
            default: break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func runFinished(_ id: Conversation.ID) {
        guard let taskID = taskRuns.removeValue(forKey: id) else { return }
        let title = tasks.task(taskID)?.title ?? L("Taak")
        let last = store.conversations.first { $0.id == id }?.messages.last { $0.role == .assistant }
        if let error = last?.error {
            Notifier.shared.post(title: L("Taak gestopt: \(title)"), body: error, conversation: id)
        } else {
            let answer = (last?.text ?? "").split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            Notifier.shared.post(title: L("Taak klaar: \(title)"), body: answer.map(String.init) ?? L("Open het gesprek voor de uitkomst."), conversation: id)
        }
        guard taskRuns.isEmpty else { return }
        if let a = taskActivity { ProcessInfo.processInfo.endActivity(a); taskActivity = nil }
        // the model a task loaded goes again, unless the user used it meanwhile or something else runs
        if modelStartedByTasks && Settings.shared.tasksStopModel && !chat.busy {
            engine.stop()
        }
        modelStartedByTasks = false
    }

    /// A run waits for the user: say so when nobody is looking (a task, or the app in the background). A task's
    /// approval that nobody gives within a day counts as no.
    private func approvalNeeded(_ a: ChatClient.Approval) {
        let isTask = taskRuns[a.conversation] != nil
        guard isTask || !NSApp.isActive else { return }
        let title = store.conversations.first { $0.id == a.conversation }?.displayTitle ?? ""
        Notifier.shared.post(title: L("Goedkeuring nodig: \(title)"), body: a.title, conversation: a.conversation)
        guard isTask else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(24 * 3600))
            guard let self, let still = self.chat.approvals[a.conversation], still.id == a.id else { return }
            self.chat.answer(still, allow: false)
        }
    }
}
