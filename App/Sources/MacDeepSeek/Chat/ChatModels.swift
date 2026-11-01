import Foundation

struct Attachment: Codable, Identifiable, Hashable {
    var id = UUID()
    var filename: String
    /// JPEG, already scaled down for the vision tower.
    var jpeg: Data
}

struct ToolCall: Codable, Hashable {
    var id: String
    var name: String
    var arguments: String
}

struct Source: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var id: String { url }
}

/// One step of the agent loop that the user sees: "Zoeken: …", "Pagina lezen: …".
struct ToolActivity: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var done: Bool
    /// What the tool returned (shortened), shown when the user opens the step.
    var output: String? = nil
    var denied: Bool? = nil
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case system, user, assistant, tool }

    var id = UUID()
    var role: Role
    var text: String
    var reasoning: String = ""
    var attachments: [Attachment] = []
    var toolCalls: [ToolCall] = []
    var toolCallId: String? = nil
    var activities: [ToolActivity] = []
    var sources: [Source] = []
    var tokensPerSecond: Double? = nil
    var promptTokensPerSecond: Double? = nil
    var error: String? = nil
    var date = Date()

    /// Assistant turns that only carry tool calls, and the tool results, are kept for the model but folded in the UI.
    var isHidden: Bool { role == .tool || role == .system || (role == .assistant && text.isEmpty && !toolCalls.isEmpty && activities.isEmpty) }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "Nieuw gesprek"
    var messages: [ChatMessage] = []
    /// The folder the model works in for this conversation (files and commands); nil = none.
    var workspace: String? = nil
    var updated = Date()
}

/// Conversations saved as one JSON file in Application Support.
@MainActor
final class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selection: Conversation.ID?

    init() {
        if let data = try? Data(contentsOf: Paths.conversationsFile),
           let list = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = list.sorted { $0.updated > $1.updated }
        }
        if conversations.isEmpty { conversations = [Conversation()] }
        selection = conversations.first?.id
    }

    var current: Conversation? {
        get { conversations.first { $0.id == selection } }
    }

    func binding(_ id: Conversation.ID) -> Int? { conversations.firstIndex { $0.id == id } }

    func newConversation() {
        if let first = conversations.first, first.messages.isEmpty {
            selection = first.id
            return
        }
        var c = Conversation()
        // a new chat starts in the folder chosen last; it can be changed per chat
        if !Settings.shared.workspace.isEmpty { c.workspace = Settings.shared.workspace }
        conversations.insert(c, at: 0)
        selection = c.id
    }

    func delete(_ id: Conversation.ID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if selection == id { selection = conversations.first?.id }
        save()
    }

    func update(_ id: Conversation.ID, _ change: (inout Conversation) -> Void) {
        guard let i = binding(id) else { return }
        change(&conversations[i])
        conversations[i].updated = Date()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: Paths.conversationsFile, options: .atomic)
    }
}
