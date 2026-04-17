import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var toolName: String?
    var isStreaming: Bool
    /// Search tools Claude called for this response (e.g. ["github_search", "fetch_page"]).
    /// Empty when no tools were used or web search is off.
    var searchToolsUsed: [String]

    init(role: MessageRole, content: String, toolName: String? = nil, isStreaming: Bool = false, searchToolsUsed: [String] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolName = toolName
        self.isStreaming = isStreaming
        self.searchToolsUsed = searchToolsUsed
    }

    /// Preserves `id` and `timestamp` when updating an existing row (e.g. streaming deltas).
    init(id: UUID, role: MessageRole, content: String, timestamp: Date, toolName: String?, isStreaming: Bool, searchToolsUsed: [String] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.isStreaming = isStreaming
        self.searchToolsUsed = searchToolsUsed
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
        case system
    }
}

struct ConversationTurn: Codable {
    let userMessage: String
    let assistantMessage: String
    let timestamp: Date
    var toolName: String?
}
