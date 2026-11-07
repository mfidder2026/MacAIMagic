import Foundation

/// schedule_task: the model plans a task for the user ("give me my agenda every weekday at 8"). It always goes
/// through the approval card first.
enum TaskTool {
    static let toolName = "schedule_task"

    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "Plan a task that you will do on your own later or repeatedly, when the user asks for that (a reminder, a daily summary, a weekly check). The user approves it first. The prompt is what you will be asked then, so write it as a complete instruction.",
            "parameters": ["type": "object",
                           "properties": [
                               "title": ["type": "string", "description": "A short name"],
                               "prompt": ["type": "string", "description": "The instruction for each run, complete on its own"],
                               "when": ["type": "string", "enum": ["once", "daily", "weekdays", "weekly", "every"]],
                               "at": ["type": "string", "description": "For once: local date and time, YYYY-MM-DDTHH:MM"],
                               "time": ["type": "string", "description": "For daily, weekdays and weekly: HH:MM"],
                               "weekday": ["type": "string", "description": "For weekly: monday … sunday"],
                               "hours": ["type": "integer", "description": "For every: every so many hours"],
                               "from": ["type": "integer", "description": "For every: first hour of the day (0-23)"],
                               "to": ["type": "integer", "description": "For every: hour to stop (0-23)"],
                           ],
                           "required": ["title", "prompt", "when"]],
        ] as [String: Any],
    ]

    enum Problem: Error, LocalizedError {
        case missing(String)
        var errorDescription: String? { if case .missing(let what) = self { return what }; return nil }
    }

    /// The task the model asked for, or what is wrong with the request.
    static func parse(_ a: [String: Any], now: Date = Date()) throws -> ScheduledTask {
        let title = (a["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (a["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Problem.missing("title is missing") }
        guard !prompt.isEmpty else { throw Problem.missing("prompt is missing") }
        func clock() throws -> (Int, Int) {
            let parts = (a["time"] as? String ?? "").split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                throw Problem.missing("time must be HH:MM")
            }
            return (parts[0], parts[1])
        }
        func int(_ key: String) -> Int? { (a[key] as? Int) ?? (a[key] as? String).flatMap { Int($0) } ?? (a[key] as? Double).map { Int($0) } }
        let schedule: TaskSchedule
        switch (a["when"] as? String ?? "").lowercased() {
        case "once":
            guard let at = CalendarConnector.date(a["at"] as? String), at > now else {
                throw Problem.missing("at must be a moment in the future, YYYY-MM-DDTHH:MM")
            }
            schedule = .once(at)
        case "daily":
            let (h, m) = try clock(); schedule = .daily(hour: h, minute: m, weekdaysOnly: false)
        case "weekdays":
            let (h, m) = try clock(); schedule = .daily(hour: h, minute: m, weekdaysOnly: true)
        case "weekly":
            let (h, m) = try clock()
            guard let wd = weekday(a["weekday"]) else { throw Problem.missing("weekday must be monday … sunday") }
            schedule = .weekly(weekday: wd, hour: h, minute: m)
        case "every":
            let hours = int("hours") ?? 1
            guard (1...24).contains(hours) else { throw Problem.missing("hours must be 1 to 24") }
            schedule = .every(hours: hours, from: min(max(int("from") ?? 0, 0), 23), to: min(max(int("to") ?? 0, 0), 23))
        default:
            throw Problem.missing("when must be once, daily, weekdays, weekly or every")
        }
        return ScheduledTask(title: String(title.prefix(80)), prompt: prompt, schedule: schedule)
    }

    /// 1 = Sunday … 7 = Saturday, from a number or an English or Dutch name.
    static func weekday(_ value: Any?) -> Int? {
        if let n = value as? Int { return (1...7).contains(n) ? n : nil }
        guard let s = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let n = Int(s) { return (1...7).contains(n) ? n : nil }
        let names = [["sunday", "zondag", "sonntag", "dimanche"], ["monday", "maandag", "montag", "lundi"],
                     ["tuesday", "dinsdag", "dienstag", "mardi"], ["wednesday", "woensdag", "mittwoch", "mercredi"],
                     ["thursday", "donderdag", "donnerstag", "jeudi"], ["friday", "vrijdag", "freitag", "vendredi"],
                     ["saturday", "zaterdag", "samstag", "samedi"]]
        return names.firstIndex { $0.contains(s) }.map { $0 + 1 }
    }
}
