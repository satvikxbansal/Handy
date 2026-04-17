import Foundation

// MARK: - Result Types

struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

struct GitHubRepoResult {
    let name: String
    let fullName: String
    let description: String
    let url: String
    let stars: Int
    let language: String?
    let lastUpdated: String
}

enum WebSearchError: LocalizedError {
    case noAPIKey(String)
    case httpError(Int, String)
    case networkError(Error)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let name): return "No \(name) API key configured."
        case .httpError(let code, let msg): return "Search API error (\(code)): \(msg)"
        case .networkError(let err): return "Search network error: \(err.localizedDescription)"
        case .decodingError: return "Failed to parse search results."
        }
    }
}

/// Modular web search service. Talks to Brave Search, Jina Reader, and GitHub REST APIs.
/// Completely independent of ClaudeAPIService and HandyManager.
/// All methods are gated on their respective Keychain keys being present.
final class WebSearchService {
    static let shared = WebSearchService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// Whether the minimum required key (Brave) is available for web search.
    var isAvailable: Bool {
        KeychainManager.hasAPIKey(.braveSearch)
    }

    // MARK: - Brave Search

    /// Searches the web via Brave Search API. Returns up to `count` results.
    /// Requires a Brave Search API key in Keychain.
    func searchBrave(query: String, count: Int = 5) async throws -> [WebSearchResult] {
        guard let apiKey = KeychainManager.getAPIKey(.braveSearch) else {
            throw WebSearchError.noAPIKey("Brave Search")
        }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "text_decorations", value: "false"),
            URLQueryItem(name: "search_lang", value: "en")
        ]

        guard let url = components.url else {
            throw WebSearchError.decodingError
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.decodingError
        }
        guard httpResponse.statusCode == 200 else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            // Extract a short, clean error message — never pass raw HTML/JSON to Claude
            let cleanMsg: String
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                cleanMsg = "Authentication failed — the Brave Search API key is invalid or expired. Please update it in Settings > Brain > Web Search."
            } else if httpResponse.statusCode == 429 {
                cleanMsg = "Rate limit exceeded — too many search requests. Please wait a moment."
            } else {
                cleanMsg = "HTTP \(httpResponse.statusCode)"
            }
            print("⚠️ Brave Search API error \(httpResponse.statusCode): \(rawBody.prefix(200))")
            throw WebSearchError.httpError(httpResponse.statusCode, cleanMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webResults = json["web"] as? [String: Any],
              let results = webResults["results"] as? [[String: Any]] else {
            return []
        }

        return results.prefix(count).compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            let snippet = item["description"] as? String ?? ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }

    // MARK: - Jina Reader

    /// Fetches and converts a web page to clean LLM-ready markdown via Jina Reader API.
    /// Falls back gracefully if no Jina key is configured (uses free tier with lower rate limits).
    func fetchPage(url pageURL: String) async throws -> String {
        guard let encodedURL = pageURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://r.jina.ai/\(encodedURL)") else {
            throw WebSearchError.decodingError
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        if let jinaKey = KeychainManager.getAPIKey(.jinaReader), !jinaKey.isEmpty {
            request.setValue("Bearer \(jinaKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.decodingError
        }
        guard httpResponse.statusCode == 200 else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            print("⚠️ Jina Reader API error \(httpResponse.statusCode): \(rawBody.prefix(200))")
            let cleanMsg = httpResponse.statusCode == 429
                ? "Rate limit exceeded for page reading. Please wait a moment."
                : "Failed to read page (HTTP \(httpResponse.statusCode))."
            throw WebSearchError.httpError(httpResponse.statusCode, cleanMsg)
        }

        let fullText = String(data: data, encoding: .utf8) ?? ""

        // Cap at ~4000 tokens (~16000 chars) to avoid context bloat
        let maxChars = 16000
        if fullText.count > maxChars {
            return String(fullText.prefix(maxChars)) + "\n\n[content truncated]"
        }
        return fullText
    }

    // MARK: - GitHub Search

    /// Searches GitHub repositories. Free API — works without a token (10 req/min),
    /// or with a GitHub token for higher rate limits (30 req/min).
    func searchGitHub(query: String, language: String? = nil) async throws -> [GitHubRepoResult] {
        var searchQuery = query
        if let lang = language, !lang.isEmpty {
            searchQuery += "+language:\(lang)"
        }

        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "5")
        ]

        guard let url = components.url else {
            throw WebSearchError.decodingError
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        if let token = KeychainManager.getAPIKey(.github), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.decodingError
        }
        guard httpResponse.statusCode == 200 else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            print("⚠️ GitHub API error \(httpResponse.statusCode): \(rawBody.prefix(200))")
            let cleanMsg = httpResponse.statusCode == 403
                ? "GitHub API rate limit reached. Add a GitHub token in Settings to increase limits."
                : "GitHub search failed (HTTP \(httpResponse.statusCode))."
            throw WebSearchError.httpError(httpResponse.statusCode, cleanMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        return items.prefix(5).compactMap { item in
            guard let name = item["name"] as? String,
                  let fullName = item["full_name"] as? String,
                  let htmlURL = item["html_url"] as? String else { return nil }
            let desc = item["description"] as? String ?? "No description"
            let stars = item["stargazers_count"] as? Int ?? 0
            let lang = item["language"] as? String
            let updated = item["updated_at"] as? String ?? ""
            return GitHubRepoResult(
                name: name, fullName: fullName, description: desc,
                url: htmlURL, stars: stars, language: lang, lastUpdated: updated
            )
        }
    }

    // MARK: - Heuristic Pre-Check

    enum SearchConfidence {
        case definitelyNeeds(suggestedQuery: String)
        case uncertain
    }

    /// Fast local regex scan (~<1ms) for queries that obviously need web search.
    /// Used to speculatively pre-fetch results in parallel with Claude's API call,
    /// hiding search latency for the most common patterns.
    /// Returns `.uncertain` for most queries — Claude handles those via tool use.
    func quickSearchCheck(_ userQuery: String) -> SearchConfidence {
        let lower = userQuery.lowercased()

        let recencyPatterns = [
            "latest version", "newest version", "current version",
            "what's new in", "what is new in", "recently released",
            "just came out", "is .* out yet", "release notes",
            "changelog", "breaking changes in", "what changed in"
        ]

        let discoveryPatterns = [
            "is there a (package|library|repo|framework|sdk|tool) for",
            "best (package|library|framework|tool) for",
            "find a (repo|repository|package|library)",
            "alternative to", "something like",
            "recommend a (library|package|framework|tool)"
        ]

        let installPatterns = [
            "how to (install|setup|set up|configure|add)",
            "npm install", "pip install", "brew install",
            "pod install", "swift package", "add.*dependency",
            "import.*sdk", "cargo add", "go get"
        ]

        let versionPatterns = [
            "v\\d+\\.\\d+", "version \\d+",
            "\\d{4} (update|release|version)"
        ]

        let allPatterns = recencyPatterns + discoveryPatterns + installPatterns + versionPatterns

        for pattern in allPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
                if regex.firstMatch(in: lower, options: [], range: range) != nil {
                    return .definitelyNeeds(suggestedQuery: userQuery)
                }
            }
        }

        return .uncertain
    }

    // MARK: - Format Results for Claude

    /// Converts search results into a concise text block for injection into Claude's context.
    static func formatSearchResults(_ results: [WebSearchResult]) -> String {
        if results.isEmpty { return "No web results found." }
        return results.enumerated().map { i, r in
            "[\(i+1)] \(r.title)\n    \(r.url)\n    \(r.snippet)"
        }.joined(separator: "\n\n")
    }

    static func formatGitHubResults(_ results: [GitHubRepoResult]) -> String {
        if results.isEmpty { return "No GitHub repositories found." }
        return results.enumerated().map { i, r in
            "[\(i+1)] \(r.fullName) (\(r.stars) stars)\n    \(r.url)\n    \(r.description)\(r.language.map { " [lang: \($0)]" } ?? "")"
        }.joined(separator: "\n\n")
    }
}
