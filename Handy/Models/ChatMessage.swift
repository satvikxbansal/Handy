import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var toolName: String?
    var isStreaming: Bool

    init(role: MessageRole, content: String, toolName: String? = nil, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolName = toolName
        self.isStreaming = isStreaming
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
