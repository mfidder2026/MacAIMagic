import SwiftUI
import AppKit

/// Taken: what the model does on its own, when it runs next, and the conversations of the last runs.
struct TasksView: View {
    var open: (Pane) -> Void
    @EnvironmentObject var app: AppState
    @EnvironmentObject var tasks: TaskStore
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var chat: ChatClient
    @State private var editing: Editing?

    private struct Editing: Identifiable { let task: ScheduledTask; let isNew: Bool; let id = UUID() }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Een taak is een opdracht die het model zelf uitvoert, op een vast moment. Elke keer wordt het een gesprek dat je hieronder terugvindt. Een wijziging vraagt eerst jouw goedkeuring; je krijgt dan een melding."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HelpButton(topic: "tasks")
                }
                HStack {
                    Button(L("Nieuwe taak…")) {
                        editing = Editing(task: ScheduledTask(title: "", prompt: "", schedule: .daily(hour: 8, minute: 0, weekdaysOnly: true)), isNew: true)
                    }
                    Text(L("Of vraag het in een gesprek: \"Geef me elke werkdag om 8 uur mijn agenda.\"")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Taken")) {
                if tasks.tasks.isEmpty {
                    Text(L("Nog geen taken.")).foregroundStyle(.secondary)
                }
                ForEach(tasks.tasks) { t in row(t) }
            }
            let runs = store.conversations.filter { $0.task != nil && $0.hidden != true }.prefix(30)
            Section(L("Laatste uitvoeringen")) {
                if runs.isEmpty { Text(L("Nog niets uitgevoerd.")).foregroundStyle(.secondary) }
                ForEach(Array(runs)) { c in
                    Button { store.selection = c.id; open(.chat(c.id)) } label: {
                        HStack {
                            if chat.approvals[c.id] != nil {
                                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber).help(L("Wacht op jouw goedkeuring"))
                            } else if chat.isBusy(c.id) {
                                ProgressView().controlSize(.mini)
                            } else if c.messages.last?.error != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            } else {
                                Image(systemName: "checkmark.circle").foregroundStyle(Theme.mint)
                            }
                            Text(c.displayTitle).lineLimit(1)
                            Spacer()
                            Text(c.updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Taken"))
        .sheet(item: $editing) { e in
            TaskEditor(task: e.task, isNew: e.isNew) { editing = nil }
        }
    }

    @ViewBuilder private func row(_ t: ScheduledTask) -> some View {
        let starting = app.tasksStarting.contains(t.id)
        let running = starting || app.taskRuns.values.contains(t.id)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { t.enabled }, set: { on in var c = t; c.enabled = on; tasks.upsert(c) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.title).font(.body.weight(.medium))
                    if running { ProgressView().controlSize(.mini) }
                    if starting { Text(L("Model laden…")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(subtitle(t)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(L("Nu uitvoeren")) { tasks.markRun(t.id); Task { await app.runTask(t) } }
                .disabled(running)
            Menu {
                Button(L("Bewerken…")) { editing = Editing(task: t, isNew: false) }
                if let last = t.lastConversation, store.conversations.contains(where: { $0.id == last }) {
                    Button(L("Laatste uitvoering openen")) { store.selection = last; open(.chat(last)) }
                }
                Divider()
                Button(L("Verwijderen"), role: .destructive) { tasks.remove(t.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func subtitle(_ t: ScheduledTask) -> String {
        var parts = [t.schedule.description]
        if t.enabled, let next = t.nextRun {
            parts.append(L("volgende: \(next.formatted(date: .abbreviated, time: .shortened))"))
        } else if !t.enabled {
            parts.append(L("staat uit"))
        }
        if let ws = t.workspace { parts.append((ws as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}

/// Nieuwe taak / Taak bewerken.
struct TaskEditor: View {
    @EnvironmentObject var tasks: TaskStore
    @State var task: ScheduledTask
    let isNew: Bool
    var done: () -> Void

    @State private var kind = 1
    @State private var at = Date().addingTimeInterval(3600)
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdaysOnly = true
    @State private var weekday = 2
    @State private var hours = 2
    @State private var from = 8
    @State private var to = 22

    init(task: ScheduledTask, isNew: Bool, done: @escaping () -> Void) {
        _task = State(initialValue: task)
        self.isNew = isNew
        self.done = done
        let cal = Calendar.current
        func clock(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
        switch task.schedule {
        case .once(let d): _kind = State(initialValue: 0); _at = State(initialValue: d)
        case .daily(let h, let m, let w): _kind = State(initialValue: 1); _time = State(initialValue: clock(h, m)); _weekdaysOnly = State(initialValue: w)
        case .weekly(let wd, let h, let m): _kind = State(initialValue: 2); _weekday = State(initialValue: wd); _time = State(initialValue: clock(h, m))
        case .every(let n, let f, let t): _kind = State(initialValue: 3); _hours = State(initialValue: n); _from = State(initialValue: f); _to = State(initialValue: t)
        }
    }

    private var schedule: TaskSchedule {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        switch kind {
        case 0: return .once(at)
        case 2: return .weekly(weekday: weekday, hour: c.hour ?? 8, minute: c.minute ?? 0)
        case 3: return .every(hours: hours, from: from, to: to)
        default: return .daily(hour: c.hour ?? 8, minute: c.minute ?? 0, weekdaysOnly: weekdaysOnly)
        }
    }

    private var problem: String? {
        if task.title.trimmingCharacters(in: .whitespaces).isEmpty { return L("Geef de taak een naam.") }
        if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("Schrijf wat het model moet doen.") }
        if case .once(let d) = schedule, d <= Date() { return L("Kies een moment in de toekomst.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? L("Nieuwe taak") : L("Taak bewerken")).font(.headline)
            Form {
                TextField(L("Naam"), text: $task.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Opdracht voor het model"))
                    TextEditor(text: $task.prompt).font(.callout).frame(height: 90)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
                Picker(L("Wanneer"), selection: $kind) {
                    Text(L("Eenmalig")).tag(0)
                    Text(L("Dagelijks")).tag(1)
                    Text(L("Wekelijks")).tag(2)
                    Text(L("Elke paar uur")).tag(3)
                }
                switch kind {
                case 0:
                    DatePicker(L("Moment"), selection: $at, in: Date()...)
                case 2:
                    Picker(L("Dag"), selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in Text(weekdayName(d)).tag(d) }
                    }
                    DatePicker(L("Tijd"), selection: $time, displayedComponents: .hourAndMinute)
                case 3:
                    Stepper(value: $hours, in: 1...12) { Text(hours == 1 ? L("Elk uur") : L("Elke \(hours) uur")) }
                    Picker(L("Van"), selection: $from) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker(L("Tot"), selection: $to) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                default:
                    DatePicker(L("Tijd"), selection: $time, displayedComponents: .hourAndMinute)
                    Toggle(L("Alleen op werkdagen"), isOn: $weekdaysOnly)
                }
                HStack {
                    Text(L("Werkmap"))
                    Spacer()
                    Text(task.workspace.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("geen")).foregroundStyle(.secondary).lineLimit(1)
                    Button(L("Kies…")) { chooseFolder() }
                    if task.workspace != nil { Button(L("Geen")) { task.workspace = nil } }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(problem ?? schedule.description).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Annuleren"), role: .cancel) { done() }
                Button(L("Bewaar")) {
                    task.title = task.title.trimmingCharacters(in: .whitespaces)
                    task.schedule = schedule
                    if isNew { task.enabled = true }
                    tasks.upsert(task)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private func weekdayName(_ d: Int) -> String {
        var cal = Calendar.current
        cal.locale = Locale(identifier: AppLanguage.current.rawValue)
        return cal.weekdaySymbols[d - 1]
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { task.workspace = url.path }
    }
}
