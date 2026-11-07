import Foundation

/// task_list: the model sets up a larger piece of work in steps and ticks them off, so the user sees where it is.
enum WorkSteps {
    static let toolName = "task_list"

    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "Show the user your plan for a task of three steps or more, and keep it up to date: call it first with all steps, and again whenever a step starts or is done (always the whole list). Not for a simple question.",
            "parameters": ["type": "object",
                           "properties": ["steps": ["type": "array", "items": [
                               "type": "object",
                               "properties": ["title": ["type": "string", "description": "The step, a few words"],
                                              "status": ["type": "string", "enum": ["todo", "doing", "done"]]],
                               "required": ["title", "status"]]]],
                           "required": ["steps"]],
        ] as [String: Any],
    ]

    /// The steps from the model's call; a status it made up counts as todo, and at most 30 steps.
    static func parse(_ arguments: [String: Any]) -> [WorkStep]? {
        guard let list = arguments["steps"] as? [[String: Any]] else { return nil }
        let steps = list.compactMap { item -> WorkStep? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let status = (item["status"] as? String ?? "").lowercased()
            return WorkStep(title: String(title.prefix(120)), status: ["todo", "doing", "done"].contains(status) ? status : "todo")
        }
        return steps.isEmpty ? nil : Array(steps.prefix(30))
    }

    /// What the model hears back.
    static func summary(_ steps: [WorkStep]) -> String {
        let done = steps.filter(\.isDone).count
        let doing = steps.filter { $0.status == "doing" }.map(\.title)
        return "Task list updated: \(done) of \(steps.count) done" + (doing.isEmpty ? "." : "; now: " + doing.joined(separator: ", ") + ".")
    }

    static func label(_ steps: [WorkStep]?) -> String {
        guard let steps else { return L("Stappenlijst") }
        return L("Stappenlijst: \(steps.filter(\.isDone).count) van \(steps.count) klaar")
    }
}
