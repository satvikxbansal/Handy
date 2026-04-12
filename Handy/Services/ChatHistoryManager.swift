import Foundation

/// Manages persistent chat history, keyed by tool/app name.
/// History stored locally as JSON in Application Support.
final class ChatHistoryManager {
    static let shared = ChatHistoryManager()

    private let maxHistoryPerTool = 100
    private let storageDirectory: URL

    private var cache: [String: [ConversationTurn]] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDirectory = appSupport.appendingPathComponent("Handy/ChatHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    func loadHistory(for toolName: String) -> [ConversationTurn] {
        let key = sanitizeKey(toolName)

        if let cached = cache[key] {
            return cached
        }

        let fileURL = storageDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: fileURL),
              let turns = try? JSONDecoder().decode([ConversationTurn].self, from: data) else {
            return []
        }

        cache[key] = turns
        return turns
    }

    func addTurn(_ turn: ConversationTurn, for toolName: String) {
        let key = sanitizeKey(toolName)
        var history = loadHistory(for: toolName)
        history.append(turn)

        if history.count > maxHistoryPerTool {
            history = Array(history.suffix(maxHistoryPerTool))
        }

        cache[key] = history
        persist(history, for: key)
    }

    func clearHistory(for toolName: String) {
        let key = sanitizeKey(toolName)
        cache[key] = nil
        let fileURL = storageDirectory.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns last N turns for API context (capped at 10 or available count)
    func recentTurns(for toolName: String, count: Int = 10) -> [ConversationTurn] {
        let history = loadHistory(for: toolName)
        return Array(history.suffix(min(count, history.count)))
    }

    /// Returns a list of all tool names that have chat history
    func allToolNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func persist(_ turns: [ConversationTurn], for key: String) {
        let fileURL = storageDirectory.appendingPathComponent("\(key).json")
        guard let data = try? JSONEncoder().encode(turns) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func sanitizeKey(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return name.components(separatedBy: allowed.inverted).joined(separator: "_").lowercased()
    }
}
