import Foundation

/// When a task runs.
enum TaskSchedule: Codable, Hashable {
    /// Once, at this moment.
    case once(Date)
    /// Every day (or only Monday to Friday) at this time.
    case daily(hour: Int, minute: Int, weekdaysOnly: Bool)
    /// Every week on this day (1 = Sunday … 7 = Saturday, as Calendar counts) at this time.
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// Every so many hours, on the hour, from `from` up to (not including) `to`; from == to is the whole day.
    case every(hours: Int, from: Int, to: Int)

    /// The first moment after `date` this schedule says to run, or nil (a single run that is past).
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once(let at):
            return at > date ? at : nil
        case .daily(let h, let m, let weekdaysOnly):
            var from = date
            for _ in 0..<10 {
                guard let d = calendar.nextDate(after: from, matching: DateComponents(hour: h, minute: m, second: 0),
                                                matchingPolicy: .nextTime) else { return nil }
                if !weekdaysOnly || !calendar.isDateInWeekend(d) { return d }
                from = d
            }
            return nil
        case .weekly(let wd, let h, let m):
            return calendar.nextDate(after: date, matching: DateComponents(hour: h, minute: m, second: 0, weekday: wd),
                                     matchingPolicy: .nextTime)
        case .every(let hours, let from, let to):
            let step = max(1, min(hours, 24))
            let end = from == to ? from + 24 : (to > from ? to : to + 24)
            let today = calendar.startOfDay(for: date)
            for dayOffset in 0..<3 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                var hour = from
                while hour < end {
                    // past midnight (a window such as 22–02) the hour belongs to the next day
                    if let base = calendar.date(byAdding: .day, value: hour / 24, to: day),
                       let d = calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: base), d > date {
                        return d
                    }
                    hour += step
                }
            }
            return nil
        }
    }

    /// In ordinary words, for the list.
    var description: String {
        let time = { (h: Int, m: Int) in String(format: "%02d:%02d", h, m) }
        switch self {
        case .once(let at):
            return L("Eenmalig, \(at.formatted(date: .abbreviated, time: .shortened))")
        case .daily(let h, let m, let weekdaysOnly):
            return weekdaysOnly ? L("Elke werkdag om \(time(h, m))") : L("Elke dag om \(time(h, m))")
        case .weekly(let wd, let h, let m):
            var cal = Calendar.current
            cal.locale = Locale(identifier: AppLanguage.current.rawValue)
            let names = cal.weekdaySymbols
            let name = names.indices.contains(wd - 1) ? names[wd - 1] : "?"
            return L("Elke \(name) om \(time(h, m))")
        case .every(let hours, let from, let to):
            let span = from == to ? L("de hele dag") : L("van \(time(from, 0)) tot \(time(to % 24, 0))")
            return hours == 1 ? L("Elk uur, \(span)") : L("Elke \(hours) uur, \(span)")
        }
    }
}

/// A task the model does on its own: a prompt, when, and in which folder.
struct ScheduledTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var prompt: String
    var schedule: TaskSchedule
    /// The work folder of its conversations (nil: none).
    var workspace: String? = nil
    var enabled = true
    var created = Date()
    var lastRun: Date? = nil
    /// When it runs next; set by the store whenever the task or the schedule changes.
    var nextRun: Date? = nil
    /// The conversation of its last run.
    var lastConversation: UUID? = nil
    /// A run that was missed by too much (the Mac was off for a day) and was not made up for.
    var lastSkipped: Date? = nil
}

/// The tasks, saved as one JSON file in Application Support.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask] = []
    let file: URL

    /// A run missed by at most this long is made up for, once; an older one is skipped (a morning briefing is no use
    /// at night).
    static let catchUpWindow: TimeInterval = 12 * 3600

    init(file: URL = Paths.tasks) {
        self.file = file
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            tasks = list
        }
    }

    func task(_ id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    /// Adds or replaces it, with its next run worked out.
    func upsert(_ task: ScheduledTask, now: Date = Date()) {
        var t = task
        t.nextRun = t.enabled ? t.schedule.next(after: now) : nil
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        save()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// The tasks that are due now, in order. Each comes once: its next run moves on at once. One that was missed by
    /// more than the catch-up window is skipped and moves on as well.
    func takeDue(now: Date = Date()) -> [ScheduledTask] {
        var due: [ScheduledTask] = []
        for i in tasks.indices where tasks[i].enabled {
            guard let next = tasks[i].nextRun, next <= now else { continue }
            if now.timeIntervalSince(next) > Self.catchUpWindow {
                tasks[i].lastSkipped = next
            } else {
                tasks[i].lastRun = now
                due.append(tasks[i])
            }
            tasks[i].nextRun = tasks[i].schedule.next(after: now)
            if tasks[i].nextRun == nil { tasks[i].enabled = false }     // a single run is done
        }
        if !due.isEmpty || tasks.contains(where: { $0.lastSkipped != nil }) { save() }
        return due.sorted { ($0.lastRun ?? now) < ($1.lastRun ?? now) }
    }

    /// The run's conversation, for the list.
    func ran(_ id: UUID, conversation: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].lastConversation = conversation
        save()
    }

    /// The task runs now, besides its schedule (Nu uitvoeren).
    func markRun(_ id: UUID, now: Date = Date()) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].lastRun = now
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(tasks) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
