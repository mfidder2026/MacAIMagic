import AppKit

/// Runs the scheduled tasks: on time, with the model started when needed and stopped again afterwards, each run a
/// conversation of its own, and a notification when it is done or needs the user.
extension AppState {
    /// Called once the window is there: the timer, waking from sleep, and the chat client's signals.
    func startTasks() {
        guard taskTimer == nil else { return }
        Notifier.shared.setUp()
        chat.onFinished = { [weak self] id in
            self?.runFinished(id)
            self?.speakIfWanted(id)
        }
        chat.onSend = { [weak self] id in
            // the user used the model: it is theirs now, a task must not stop it
            if self?.taskRuns[id] == nil { self?.modelStartedByTasks = false }
        }
        chat.onApproval = { [weak self] a in
            guard let self else { return }
            self.approvalNeeded(a)
            self.telegram.approval(a, isTask: self.taskRuns[a.conversation] != nil)
        }
        _ = telegram
        TelegramService.shared.start()
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
        if Heartbeat.isDue(now: now) { Task { await heartbeat() } }
    }

    /// One heartbeat: the model goes through the checklist and only speaks up when something needs the user. A check
    /// with nothing to report leaves no conversation behind.
    func heartbeat(now: Date = Date(), forced: Bool = false) async {
        Heartbeat.lastRun = now
        let time = now.formatted(date: .omitted, time: .shortened)
        guard let checklist = Heartbeat.checklist() else {
            heartbeatStatus = L("\(time): overgeslagen, de checklist is leeg.")
            return
        }
        // the user and the tasks go first
        guard forced || (!chat.busy && taskRuns.isEmpty) else {
            heartbeatStatus = L("\(time): overgeslagen, het model was bezig.")
            return
        }
        guard engine.state.isRunning || forced || Settings.shared.heartbeatMayLoad else {
            heartbeatStatus = L("\(time): overgeslagen, het model was niet geladen.")
            return
        }
        guard await ensureModel() else {
            heartbeatStatus = L("\(time): het model kon niet starten.")
            return
        }
        var c = Conversation(title: "♥ " + L("Controle") + " · " + now.formatted(date: .abbreviated, time: .shortened))
        c.task = Heartbeat.taskID
        c.hidden = true
        store.conversations.insert(c, at: 0)
        taskRuns[c.id] = Heartbeat.taskID
        heartbeatStatus = L("\(time): bezig met controleren…")
        chat.send(text: Heartbeat.prompt(checklist), attachments: [], in: c.id, store: store, baseURL: engine.baseURL)
    }

    /// One run of a task: a new conversation with its prompt. Nil when the model could not start.
    @discardableResult
    func runTask(_ task: ScheduledTask) async -> Conversation.ID? {
        tasksStarting.insert(task.id)
        let ready = await ensureModel()
        tasksStarting.remove(task.id)
        guard ready else {
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
            await startBegun()
        }
        let start = Date()
        // a "failed" or "stopped" from before this start is old news: only after the engine was starting (or after a
        // grace) does it mean this start failed. Before, a task gave up at once and the engine loaded anyway.
        var sawStarting = false
        while Date().timeIntervalSince(start) < 1800 {
            let waited = Date().timeIntervalSince(start)
            switch engine.state {
            case .running: return true
            case .starting: sawStarting = true
            case .failed where sawStarting || waited > 15: return false
            case .stopped where sawStarting || waited > 15: return false
            default: break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Instellingen → Agent → "Lees antwoorden voor": the answer of a conversation on screen, not of a task or Telegram.
    private func speakIfWanted(_ id: Conversation.ID) {
        let s = Settings.shared
        guard s.featureVoice, s.speakAnswers, taskRuns[id] == nil, NSApp.isActive,
              let c = store.conversations.first(where: { $0.id == id }), c.telegram == nil, c.task == nil,
              let last = c.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty && $0.error == nil }) else { return }
        Voice.shared.speak(last.text, id: last.id)
    }

    private func runFinished(_ id: Conversation.ID) {
        guard let taskID = taskRuns.removeValue(forKey: id) else { return }
        if taskID == Heartbeat.taskID {
            heartbeatFinished(id)
        } else {
            taskNotification(id, taskID)
        }
        guard taskRuns.isEmpty else { return }
        if let a = taskActivity { ProcessInfo.processInfo.endActivity(a); taskActivity = nil }
        // the model a task loaded goes again, unless the user used it meanwhile or something else runs
        if modelStartedByTasks && Settings.shared.tasksStopModel && !chat.busy {
            engine.stop()
        }
        modelStartedByTasks = false
    }

    private func heartbeatFinished(_ id: Conversation.ID) {
        let time = Date().formatted(date: .omitted, time: .shortened)
        let last = store.conversations.first { $0.id == id }?.messages.last { $0.role == .assistant }
        if last?.error == nil, Heartbeat.isNothing(last?.text ?? "") {
            store.delete(id)
            heartbeatStatus = L("Laatste controle \(time): niets te melden.")
            return
        }
        // something to say: the conversation shows, under Taken and in the sidebar
        store.update(id) { $0.hidden = nil }
        store.save()
        let answer = last?.error ?? (last?.text ?? "").split(separator: "\n").first.map(String.init) ?? ""
        heartbeatStatus = L("Laatste controle \(time): er is iets te melden.")
        Notifier.shared.post(title: L("MacAIMagic heeft iets voor je"), body: answer, conversation: id)
        telegram.notify(L("MacAIMagic heeft iets voor je"), last?.error ?? last?.text ?? "")
    }

    private func taskNotification(_ id: Conversation.ID, _ taskID: UUID) {
        let title = tasks.task(taskID)?.title ?? L("Taak")
        let last = store.conversations.first { $0.id == id }?.messages.last { $0.role == .assistant }
        if let error = last?.error {
            Notifier.shared.post(title: L("Taak gestopt: \(title)"), body: error, conversation: id)
            telegram.notify(L("Taak gestopt: \(title)"), error)
        } else {
            let answer = (last?.text ?? "").split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            Notifier.shared.post(title: L("Taak klaar: \(title)"), body: answer.map(String.init) ?? L("Open het gesprek voor de uitkomst."), conversation: id)
            telegram.notify(L("Taak klaar: \(title)"), ChatClient.withoutDoneWord(last?.text ?? ""))
        }
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

/// The heartbeat: every so often, within the active hours, the model goes through HEARTBEAT.md.
enum Heartbeat {
    /// Marks heartbeat conversations (Conversation.task) and runs.
    static let taskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    static var lastRun: Date? {
        get { let t = UserDefaults.standard.double(forKey: "heartbeatLast"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "heartbeatLast") }
    }

    /// On, inside the active hours, and the interval has passed since the last one.
    @MainActor static func isDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let s = Settings.shared
        guard s.heartbeat else { return false }
        return isDue(now: now, last: lastRun, minutes: s.heartbeatMinutes, from: s.heartbeatFrom, to: s.heartbeatTo, calendar: calendar)
    }

    static func isDue(now: Date, last: Date?, minutes: Int, from: Int, to: Int, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        let inside = from == to || (from < to ? (from..<to).contains(hour) : (hour >= from || hour < to))
        guard inside else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Double(max(minutes, 5)) * 60 - 1
    }

    /// The checklist, made with an example the first time; nil when there is nothing on it but headings and comments.
    static func checklist(file: URL = Paths.heartbeat) -> String? {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? example.write(to: file, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let items = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") && !$0.hasPrefix(">") }
        return items.isEmpty ? nil : String(text.prefix(6000))
    }

    static func prompt(_ checklist: String) -> String {
        L("Dit is een geplande controle (heartbeat), de gebruiker kijkt nu niet mee. Loop de checklist hieronder na met je gereedschap. Is er niets dat de gebruiker nu moet weten, antwoord dan alleen met het woord NIETS. Is er wel iets, zeg dan in een paar zinnen wat en waarom; begin met het belangrijkste.")
            + "\n\n" + checklist
    }

    /// The model had nothing to report.
    static func isNothing(_ answer: String) -> Bool {
        let word = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_.!\"'`")).uppercased()
        return ["NIETS", "NOTHING", "NICHTS", "RIEN", "HEARTBEAT_OK", "KLAAR: NIETS", "KLAAR NIETS"].contains(word)
    }

    /// The first checklist, in Dutch or English (the file is the user's to edit, in any language).
    static var example: String {
        AppLanguage.current == .nl ? """
        # Checklist voor de heartbeat

        > Het model loopt deze lijst na, elke keer dat de heartbeat komt. Het meldt zich alleen als er iets is.
        > Regels die beginnen met # of > zijn uitleg; zet je eigen punten eronder, één per regel.

        > Voorbeelden (haal het > weg om er een te gebruiken):
        > - Staat er in het komende uur een afspraak in mijn agenda? Noem hem dan.
        > - Is er een herinnering voor vandaag die nog open staat?
        > - Is de schijf van deze Mac voor meer dan 90% vol?
        """ : """
        # Heartbeat checklist

        > The model goes through this list at every heartbeat. It only speaks up when something needs you.
        > Lines starting with # or > are explanation; put your own points below, one per line.

        > Examples (remove the > to use one):
        > - Is there an appointment in my calendar in the coming hour? Then name it.
        > - Is there a reminder for today that is still open?
        > - Is this Mac's disk more than 90% full?
        """
    }
}
