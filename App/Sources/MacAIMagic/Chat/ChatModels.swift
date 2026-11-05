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
    /// Sent by the app, not the user: the model stopped before its work was done and is told to go on.
    var automatic: Bool? = nil

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
    /// Tokens the conversation took in the model's context at the last answer (prompt and answer).
    var contextTokens: Int? = nil
    /// Compacted: a summary of the messages up to and including `summaryUpTo`, sent instead of them.
    var summary: String? = nil
    var summaryUpTo: UUID? = nil

    /// The title in the chosen language while it is still the default.
    var displayTitle: String { title == "Nieuw gesprek" ? L("Nieuw gesprek") : title }

    /// The messages that still go to the model (after the summary).
    var unsummarized: ArraySlice<ChatMessage> {
        guard let last = summaryUpTo, let i = messages.firstIndex(where: { $0.id == last }) else { return messages[...] }
        return messages[(i + 1)...]
    }
}

/// Conversations saved as one JSON file in Application Support.
@MainActor
final class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selection: Conversation.ID?

    /// The file could not be read: it is kept as .bad and this says so to the user.
    @Published private(set) var loadProblem: String?

    init() {
        if let data = try? Data(contentsOf: Paths.conversationsFile) {
            if let list = try? JSONDecoder().decode([Conversation].self, from: data) {
                conversations = list.sorted { $0.updated > $1.updated }
            } else {
                // the next save would overwrite it: what can still be rescued stays
                let bad = Paths.conversationsFile.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: Paths.conversationsFile, to: bad)
                loadProblem = L("De gesprekken konden niet worden gelezen. Het bestand is bewaard als \(bad.lastPathComponent).")
            }
        }
        if conversations.isEmpty { conversations = [Conversation()] }
        startInLastFolder()
        selection = conversations.first?.id
    }

    var current: Conversation? {
        get { conversations.first { $0.id == selection } }
    }

    func binding(_ id: Conversation.ID) -> Int? { conversations.firstIndex { $0.id == id } }

    /// A new chat starts in the folder chosen last; it can be changed per chat.
    private func startInLastFolder() {
        guard let first = conversations.first, first.messages.isEmpty, first.workspace == nil,
              !Settings.shared.workspace.isEmpty else { return }
        conversations[0].workspace = Settings.shared.workspace
    }

    func newConversation() {
        if conversations.first?.messages.isEmpty != true { conversations.insert(Conversation(), at: 0) }
        startInLastFolder()
        selection = conversations.first?.id
    }

    func delete(_ id: Conversation.ID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        startInLastFolder()
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
