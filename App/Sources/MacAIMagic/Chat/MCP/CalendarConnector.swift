import Foundation
import EventKit

/// Agenda en Herinneringen, built into the app with EventKit: no program of someone else runs. macOS asks the user once
/// for access to the calendars and to the reminders.
final class CalendarConnector: BuiltinConnector, @unchecked Sendable {
    private let store = EKEventStore()

    static let tools: [MCPTool] = [
        MCPTool(name: "list_events", title: "Afspraken tonen",
                description: "List calendar events between two dates (ISO 8601, e.g. 2026-11-07 or 2026-11-07T09:00). Without dates: today and the next 7 days.",
                schema: ["type": "object", "properties": [
                    "from": ["type": "string", "description": "Start date/time (ISO 8601)"],
                    "to": ["type": "string", "description": "End date/time (ISO 8601)"],
                    "query": ["type": "string", "description": "Only events whose title contains this, optional"],
                ] as [String: Any]], readOnly: true),
        MCPTool(name: "create_event", title: "Afspraak maken",
                description: "Create a calendar event in the default calendar.",
                schema: ["type": "object", "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO 8601 date/time"],
                    "end": ["type": "string", "description": "ISO 8601 date/time; default one hour after start"],
                    "location": ["type": "string"],
                    "notes": ["type": "string"],
                    "all_day": ["type": "boolean"],
                ] as [String: Any], "required": ["title", "start"]], readOnly: false, destructive: false),
        MCPTool(name: "list_reminders", title: "Herinneringen tonen",
                description: "List reminders. By default only the ones that are not completed.",
                schema: ["type": "object", "properties": [
                    "include_completed": ["type": "boolean"],
                    "list": ["type": "string", "description": "Only this reminder list, optional"],
                ] as [String: Any]], readOnly: true),
        MCPTool(name: "create_reminder", title: "Herinnering maken",
                description: "Create a reminder, optionally with a due date.",
                schema: ["type": "object", "properties": [
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "ISO 8601 date/time, optional"],
                    "notes": ["type": "string"],
                    "list": ["type": "string", "description": "Reminder list, optional (default list otherwise)"],
                ] as [String: Any], "required": ["title"]], readOnly: false, destructive: false),
        MCPTool(name: "complete_reminder", title: "Herinnering afvinken",
                description: "Mark a reminder as completed, by its id from list_reminders.",
                schema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]], readOnly: false, destructive: false),
    ]

    func start() async throws -> [MCPTool] { Self.tools }

    private func access(_ type: EKEntityType) async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: type)
        }
        guard granted else {
            throw MCPError.server(0, type == .event
                ? "No access to the calendars. The user can allow it in System Settings → Privacy & Security → Calendars."
                : "No access to the reminders. The user can allow it in System Settings → Privacy & Security → Reminders.")
        }
    }

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func text(_ d: Date, allDay: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    func call(_ tool: String, arguments a: [String: Any]) async throws -> String {
        switch tool {
        case "list_events":
            try await access(.event)
            let from = Self.date(a["from"] as? String) ?? Calendar.current.startOfDay(for: Date())
            var to = Self.date(a["to"] as? String) ?? from.addingTimeInterval(8 * 86_400)
            if to <= from { to = from.addingTimeInterval(86_400) }
            let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
                .filter { q in (a["query"] as? String).map { q.title?.localizedCaseInsensitiveContains($0) ?? false } ?? true }
                .sorted { $0.startDate < $1.startDate }
            if events.isEmpty { return "No events between \(Self.text(from)) and \(Self.text(to))." }
            return events.prefix(200).map { e in
                var line = "- \(Self.text(e.startDate, allDay: e.isAllDay))" + (e.isAllDay ? " (all day)" : " – \(Self.text(e.endDate))")
                line += ": \(e.title ?? "(no title)") [\(e.calendar.title)]"
                if let l = e.location, !l.isEmpty { line += " @ \(l)" }
                return line
            }.joined(separator: "\n")

        case "create_event":
            try await access(.event)
            guard let title = a["title"] as? String, let start = Self.date(a["start"] as? String) else {
                return "Error: title and a valid start (ISO 8601) are needed."
            }
            let e = EKEvent(eventStore: store)
            e.title = title
            e.startDate = start
            e.isAllDay = a["all_day"] as? Bool ?? false
            e.endDate = Self.date(a["end"] as? String) ?? start.addingTimeInterval(e.isAllDay ? 86_400 : 3_600)
            e.location = a["location"] as? String
            e.notes = a["notes"] as? String
            e.calendar = store.defaultCalendarForNewEvents
            try store.save(e, span: .thisEvent)
            return "Created \"\(title)\" on \(Self.text(start, allDay: e.isAllDay)) in \(e.calendar.title) (id \(e.eventIdentifier ?? ""))."

        case "list_reminders":
            try await access(.reminder)
            let calendars = (a["list"] as? String).map { name in store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveContains(name) } }
            let includeDone = a["include_completed"] as? Bool ?? false
            let predicate = includeDone ? store.predicateForReminders(in: calendars)
                : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
            let reminders: [EKReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
            }
            if reminders.isEmpty { return "No reminders." }
            return reminders.prefix(200).map { r in
                var line = "- [\(r.isCompleted ? "x" : " ")] \(r.title ?? "(no title)") [\(r.calendar.title)]"
                if let due = r.dueDateComponents?.date ?? r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { line += " due \(Self.text(due))" }
                return line + " (id \(r.calendarItemIdentifier))"
            }.joined(separator: "\n")

        case "create_reminder":
            try await access(.reminder)
            guard let title = a["title"] as? String, !title.isEmpty else { return "Error: a title is needed." }
            let r = EKReminder(eventStore: store)
            r.title = title
            r.notes = a["notes"] as? String
            if let name = a["list"] as? String, let cal = store.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveContains(name) }) {
                r.calendar = cal
            } else {
                r.calendar = store.defaultCalendarForNewReminders()
            }
            if let due = Self.date(a["due"] as? String) {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            try store.save(r, commit: true)
            return "Created reminder \"\(title)\" in \(r.calendar.title) (id \(r.calendarItemIdentifier))."

        case "complete_reminder":
            try await access(.reminder)
            guard let id = a["id"] as? String, let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return "Error: no reminder with that id; use list_reminders first."
            }
            r.isCompleted = true
            try store.save(r, commit: true)
            return "Completed \"\(r.title ?? "")\"."

        default:
            return "Unknown tool \(tool)"
        }
    }
}
