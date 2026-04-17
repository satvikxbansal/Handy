import Foundation

enum ClaudeAPIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case streamingFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Claude API key found. Please add your API key in Settings."
        case .invalidResponse: return "Received an invalid response from Claude."
        case .httpError(let code, let msg): return "API error (\(code)): \(msg)"
        case .streamingFailed(let msg): return "Streaming failed: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

final class ClaudeAPIService {
    static let shared = ClaudeAPIService()

    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"
    private let model = "claude-sonnet-4-20250514"
    private let maxTokens = 2048

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
        warmUpTLSConnection()
    }

    private func warmUpTLSConnection() {
        guard let host = URL(string: baseURL)?.host,
              let warmupURL = URL(string: "https://\(host)/") else { return }
        var request = URLRequest(url: warmupURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// Streams a response from Claude with vision (screenshots) and conversation history.
    func streamResponse(
        userMessage: String,
        images: [(data: Data, label: String)],
        conversationHistory: [ConversationTurn],
        systemPrompt: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        guard let apiKey = KeychainManager.getAPIKey(.claude) else {
            onComplete(.failure(ClaudeAPIError.noAPIKey))
            return
        }

        var messages: [[String: Any]] = []

        for turn in conversationHistory.suffix(10) {
            messages.append(["role": "user", "content": turn.userMessage])
            messages.append(["role": "assistant", "content": turn.assistantMessage])
        }

        var userContent: [[String: Any]] = []

        for image in images {
            let base64 = image.data.base64EncodedString()
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
            userContent.append([
                "type": "text",
                "text": image.label
            ])
        }

        userContent.append([
            "type": "text",
            "text": userMessage
        ])

        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages,
            "stream": true
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            onComplete(.failure(ClaudeAPIError.invalidResponse))
            return
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    onComplete(.failure(ClaudeAPIError.networkError(error)))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    onComplete(.failure(ClaudeAPIError.invalidResponse))
                }
                return
            }

            guard let data else {
                DispatchQueue.main.async {
                    onComplete(.failure(ClaudeAPIError.invalidResponse))
                }
                return
            }

            if httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                DispatchQueue.main.async {
                    onComplete(.failure(ClaudeAPIError.httpError(httpResponse.statusCode, body)))
                }
                return
            }

            let fullText = self.parseSSEResponse(data: data, onChunk: onChunk)
            DispatchQueue.main.async {
                onComplete(.success(fullText))
            }
        }
        task.resume()
    }

    /// Detects the MIME type of image data by inspecting magic bytes.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Streaming via the shared URLSession using async bytes — no per-request session leak.
    func streamResponseAsync(
        userMessage: String,
        images: [(data: Data, label: String)],
        conversationHistory: [ConversationTurn],
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let apiKey = KeychainManager.getAPIKey(.claude) else {
                continuation.finish(throwing: ClaudeAPIError.noAPIKey)
                return
            }

            var messages: [[String: Any]] = []

            for turn in conversationHistory.suffix(10) {
                messages.append(["role": "user", "content": turn.userMessage])
                messages.append(["role": "assistant", "content": turn.assistantMessage])
            }

            var userContent: [[String: Any]] = []
            for image in images {
                let base64 = image.data.base64EncodedString()
                userContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": self.detectImageMediaType(for: image.data),
                        "data": base64
                    ]
                ])
                userContent.append(["type": "text", "text": image.label])
            }
            userContent.append(["type": "text", "text": userMessage])
            messages.append(["role": "user", "content": userContent])

            let body: [String: Any] = [
                "model": self.model,
                "max_tokens": self.maxTokens,
                "system": systemPrompt,
                "messages": messages,
                "stream": true
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
                continuation.finish(throwing: ClaudeAPIError.invalidResponse)
                return
            }

            var request = URLRequest(url: URL(string: self.baseURL)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(self.apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = jsonData

            let sharedSession = self.session

            Task {
                do {
                    let (byteStream, response) = try await sharedSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ClaudeAPIError.invalidResponse)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in byteStream.lines {
                            errorBody += line + "\n"
                        }
                        continuation.finish(throwing: ClaudeAPIError.httpError(httpResponse.statusCode, errorBody))
                        return
                    }

                    for try await line in byteStream.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }

                        guard let jsonData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }

                        if let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }

                        if let type = json["type"] as? String, type == "message_stop" {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ClaudeAPIError.networkError(error))
                }
            }

            continuation.onTermination = { @Sendable _ in }
        }
    }

    /// Lightweight non-streaming call that identifies the tool/app from a screenshot.
    /// `contextHints` provides known info (URL, window title, app name) to ground the LLM
    /// and prevent hallucination.
    func detectToolName(imageData: Data, contextHints: String = "") async throws -> String {
        guard let apiKey = KeychainManager.getAPIKey(.claude) else {
            throw ClaudeAPIError.noAPIKey
        }

        let base64 = imageData.base64EncodedString()
        let mediaType = detectImageMediaType(for: imageData)

        var prompt = """
        look at this screenshot and identify the specific tool, app, or website the user is actively working in. \
        return ONLY the name — nothing else. examples: "Figma", "VS Code", "Google Docs - Q3 Report", \
        "GitHub - pull request", "Slack - #engineering", "Xcode", "Final Cut Pro". \
        for browsers, identify the WEBSITE being used, not the browser name. \
        keep it short — max 5 words.
        """

        if !contextHints.isEmpty {
            prompt += "\n\ncontext from the system (use this to ground your answer): \(contextHints)"
        }

        let userContent: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": base64
                ]
            ],
            ["type": "text", "text": prompt]
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 50,
            "messages": [["role": "user", "content": userContent]]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ClaudeAPIError.invalidResponse
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else {
            throw ClaudeAPIError.invalidResponse
        }
        return trimmed
    }

    // MARK: - Web Search Tool Definitions

    /// The three tools Claude can call when web search mode is on.
    /// Descriptions encode detailed "when to use / when not to use" guidance so Claude
    /// makes good decisions without an external classifier.
    /// Returns only the tools whose required API keys are available.
    /// GitHub search and fetch_page are always included (free APIs).
    /// web_search requires a Brave API key.
    static func availableWebSearchTools() -> [[String: Any]] {
        var tools: [[String: Any]] = []
        if KeychainManager.hasAPIKey(.braveSearch) {
            tools.append(webSearchToolDef)
        }
        tools.append(fetchPageToolDef)
        tools.append(githubSearchToolDef)
        return tools
    }

    private static let webSearchToolDef: [String: Any] = [
        "name": "web_search",
        "description": """
        Search the web for current, real-time information. \
        USE when: user asks about latest versions, recent releases (anything after early 2025), \
        specific packages/libraries they want to find, "best package for", "find a repo", \
        how to install or set up software ("pip install", "npm install", "SPM package", "brew install"), \
        error codes or error messages with no obvious fix, \
        compatibility questions ("does X support Y", "is X compatible with"), \
        specific API usage or documentation ("how to use the X API", "X API documentation"), \
        changelogs, release notes, breaking changes, \
        anything recency-dependent ("what's new in", "current", "2025", "2026", "recently released"). \
        DO NOT USE when: the question is about general UI navigation (where is a button), \
        code review of visible code, explaining a concept you know well (what is a closure, explain MVC), \
        anything clearly visible on the user's screen, \
        conversation continuity ("do that again", "try a different approach"), \
        or blender/xcode/app-specific navigation that the screenshot already shows.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Optimized search query. Be specific — include framework names, language, version numbers when relevant."
                ]
            ],
            "required": ["query"]
        ] as [String: Any]
    ]

    private static let fetchPageToolDef: [String: Any] = [
        "name": "fetch_page",
        "description": """
        Fetch and read the full content of a web page. Returns clean markdown text. \
        Use when you need to read a full article, README, documentation page, or blog post. \
        You can use this with any URL — including GitHub READMEs, official docs, or blog posts. \
        Works even without web_search: if you know the URL to check, fetch it directly.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The full URL of the page to read."
                ]
            ],
            "required": ["url"]
        ] as [String: Any]
    ]

    private static let githubSearchToolDef: [String: Any] = [
        "name": "github_search",
        "description": """
        Search GitHub for repositories. Use when the user wants to find a library, \
        package, SDK, or open-source tool, or when they ask about a project's latest release, \
        stars, or activity. Also useful for version/release questions about open-source software — \
        GitHub often has the most current release info. More targeted than web_search for code discovery. \
        Returns top results sorted by stars with descriptions and last update dates.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search query for GitHub repositories."
                ],
                "language": [
                    "type": "string",
                    "description": "Programming language filter (e.g. 'swift', 'python', 'javascript'). Optional."
                ]
            ],
            "required": ["query"]
        ] as [String: Any]
    ]

    private static let webSearchTools: [[String: Any]] = [
        [
            "name": "web_search",
            "description": """
            Search the web for current, real-time information. \
            USE when: user asks about latest versions, recent releases (anything after early 2025), \
            specific packages/libraries they want to find, "best package for", "find a repo", \
            how to install or set up software ("pip install", "npm install", "SPM package", "brew install"), \
            error codes or error messages with no obvious fix, \
            compatibility questions ("does X support Y", "is X compatible with"), \
            specific API usage or documentation ("how to use the X API", "X API documentation"), \
            changelogs, release notes, breaking changes, \
            anything recency-dependent ("what's new in", "current", "2025", "2026", "recently released"). \
            DO NOT USE when: the question is about general UI navigation (where is a button), \
            code review of visible code, explaining a concept you know well (what is a closure, explain MVC), \
            anything clearly visible on the user's screen, \
            conversation continuity ("do that again", "try a different approach"), \
            or blender/xcode/app-specific navigation that the screenshot already shows.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Optimized search query. Be specific — include framework names, language, version numbers when relevant."
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ],
        [
            "name": "fetch_page",
            "description": """
            Fetch and read the full content of a web page. Returns clean markdown text. \
            Use after web_search when you need to read a full article, README, \
            documentation page, or blog post that a search result pointed to. \
            Only fetch pages that are likely to have the specific answer — don't fetch speculatively.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The full URL of the page to read."
                    ]
                ],
                "required": ["url"]
            ] as [String: Any]
        ],
        [
            "name": "github_search",
            "description": """
            Search GitHub for repositories. Use when the user wants to find a library, \
            package, SDK, or open-source tool. More targeted than web_search for code and repo discovery. \
            Returns top results sorted by stars with descriptions and last update dates.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search query for GitHub repositories."
                    ],
                    "language": [
                        "type": "string",
                        "description": "Programming language filter (e.g. 'swift', 'python', 'javascript'). Optional."
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ]
    ]

    // MARK: - Tool-Use Streaming (Web Search)

    /// Streams a response with web search tool definitions included.
    /// Claude decides whether to call tools. If it does, the tool is executed and results
    /// are sent back for a second pass. The `onToolUse` callback fires with the tool name
    /// so the caller can update UI (e.g. "Searching the web...").
    ///
    /// This method is completely separate from `streamResponseAsync` — existing non-search
    /// flows are never affected.
    func streamResponseWithToolsAsync(
        userMessage: String,
        images: [(data: Data, label: String)],
        conversationHistory: [ConversationTurn],
        systemPrompt: String,
        tools: [[String: Any]]? = nil,
        onToolUse: @escaping (String) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let apiKey = KeychainManager.getAPIKey(.claude) else {
                continuation.finish(throwing: ClaudeAPIError.noAPIKey)
                return
            }

            var messages: [[String: Any]] = []

            for turn in conversationHistory.suffix(10) {
                messages.append(["role": "user", "content": turn.userMessage])
                messages.append(["role": "assistant", "content": turn.assistantMessage])
            }

            var userContent: [[String: Any]] = []
            for image in images {
                let base64 = image.data.base64EncodedString()
                userContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": self.detectImageMediaType(for: image.data),
                        "data": base64
                    ]
                ])
                userContent.append(["type": "text", "text": image.label])
            }
            userContent.append(["type": "text", "text": userMessage])
            messages.append(["role": "user", "content": userContent])

            let resolvedTools = tools ?? Self.webSearchTools
            let toolNames = resolvedTools.compactMap { $0["name"] as? String }
            print("🌐 streamResponseWithToolsAsync — sending \(resolvedTools.count) tools: \(toolNames)")

            let body: [String: Any] = [
                "model": self.model,
                "max_tokens": self.maxTokens,
                "system": systemPrompt,
                "messages": messages,
                "tools": resolvedTools,
                "stream": true
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
                print("⚠️ Failed to serialize request body to JSON")
                continuation.finish(throwing: ClaudeAPIError.invalidResponse)
                return
            }

            let sharedSession = self.session
            let baseURLStr = self.baseURL
            let apiVersionStr = self.apiVersion
            let modelStr = self.model
            let maxTok = self.maxTokens

            Task {
                do {
                    let maxToolCalls = 5
                    var toolCallsUsed = 0
                    var currentMessages = messages
                    var currentJsonData = jsonData

                    while true {
                        let passResult = try await self.executeStreamingPass(
                            jsonData: currentJsonData,
                            apiKey: apiKey,
                            baseURL: baseURLStr,
                            apiVersion: apiVersionStr,
                            session: sharedSession,
                            continuation: continuation
                        )

                        guard let toolUse = passResult.toolUse else {
                            print("🌐 Tool loop complete after \(toolCallsUsed) tool call(s) — Claude finished with text")
                            break
                        }

                        toolCallsUsed += 1
                        print("🌐 Tool call \(toolCallsUsed)/\(maxToolCalls): \(toolUse.name) with input: \(toolUse.input)")
                        await MainActor.run { onToolUse(toolUse.name) }

                        let toolResultContent: String
                        do {
                            toolResultContent = try await self.executeTool(name: toolUse.name, input: toolUse.input)
                        } catch {
                            toolResultContent = "Tool execution failed: \(error.localizedDescription)"
                            print("⚠️ Tool execution failed: \(error)")
                        }

                        currentMessages.append([
                            "role": "assistant",
                            "content": passResult.assistantContentBlocks
                        ])
                        currentMessages.append([
                            "role": "user",
                            "content": [
                                [
                                    "type": "tool_result",
                                    "tool_use_id": toolUse.id,
                                    "content": toolResultContent
                                ]
                            ]
                        ])

                        if toolCallsUsed >= maxToolCalls {
                            // Hit the limit. One final pass WITHOUT tools so Claude
                            // MUST synthesize an answer from everything gathered so far.
                            print("🌐 Tool call limit reached (\(maxToolCalls)). Final synthesis pass (no tools).")
                            let finalBody: [String: Any] = [
                                "model": modelStr,
                                "max_tokens": maxTok,
                                "system": systemPrompt,
                                "messages": currentMessages,
                                "stream": true
                            ]
                            guard let finalJsonData = try? JSONSerialization.data(withJSONObject: finalBody) else {
                                continuation.finish(throwing: ClaudeAPIError.invalidResponse)
                                return
                            }
                            let _ = try await self.executeStreamingPass(
                                jsonData: finalJsonData,
                                apiKey: apiKey,
                                baseURL: baseURLStr,
                                apiVersion: apiVersionStr,
                                session: sharedSession,
                                continuation: continuation
                            )
                            break
                        }

                        let nextBody: [String: Any] = [
                            "model": modelStr,
                            "max_tokens": maxTok,
                            "system": systemPrompt,
                            "messages": currentMessages,
                            "tools": resolvedTools,
                            "stream": true
                        ]

                        guard let nextJsonData = try? JSONSerialization.data(withJSONObject: nextBody) else {
                            continuation.finish(throwing: ClaudeAPIError.invalidResponse)
                            return
                        }
                        currentJsonData = nextJsonData
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in }
        }
    }

    // MARK: - Streaming Pass (handles both text and tool_use)

    private struct ToolUseBlock {
        let id: String
        let name: String
        let input: [String: Any]
    }

    private struct StreamingPassResult {
        let textSoFar: String
        let toolUse: ToolUseBlock?
        let assistantContentBlocks: [[String: Any]]
    }

    /// Runs one streaming API call. Yields text chunks via continuation.
    /// If Claude emits a tool_use block, returns it in the result so the caller can execute it.
    private func executeStreamingPass(
        jsonData: Data,
        apiKey: String,
        baseURL: String,
        apiVersion: String,
        session: URLSession,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> StreamingPassResult {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in byteStream.lines {
                errorBody += line + "\n"
            }
            throw ClaudeAPIError.httpError(httpResponse.statusCode, errorBody)
        }

        var fullText = ""
        var currentToolUseId = ""
        var currentToolName = ""
        var currentToolInputJson = ""
        var isInToolUse = false
        var detectedToolUse: ToolUseBlock?
        var assistantContentBlocks: [[String: Any]] = []

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { break }

            guard let lineData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let eventType = json["type"] as? String ?? ""

            switch eventType {
            case "content_block_start":
                if let contentBlock = json["content_block"] as? [String: Any],
                   let blockType = contentBlock["type"] as? String {
                    print("🔧 SSE content_block_start: type=\(blockType)")
                    if blockType == "tool_use" {
                        isInToolUse = true
                        currentToolUseId = contentBlock["id"] as? String ?? ""
                        currentToolName = contentBlock["name"] as? String ?? ""
                        currentToolInputJson = ""
                        print("🔧   → tool_use detected: id=\(currentToolUseId) name=\(currentToolName)")
                    }
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String ?? ""
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        fullText += text
                        continuation.yield(text)
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        currentToolInputJson += partial
                    }
                }

            case "content_block_stop":
                if isInToolUse {
                    isInToolUse = false
                    let inputDict: [String: Any]
                    if let data = currentToolInputJson.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        inputDict = parsed
                    } else {
                        inputDict = [:]
                        print("⚠️ SSE tool input JSON parse failed: \(currentToolInputJson)")
                    }
                    detectedToolUse = ToolUseBlock(
                        id: currentToolUseId,
                        name: currentToolName,
                        input: inputDict
                    )
                    assistantContentBlocks.append([
                        "type": "tool_use",
                        "id": currentToolUseId,
                        "name": currentToolName,
                        "input": inputDict
                    ])
                    print("🔧 SSE tool_use block complete: \(currentToolName)(\(inputDict))")
                } else if !fullText.isEmpty {
                    assistantContentBlocks.append([
                        "type": "text",
                        "text": fullText
                    ])
                }

            case "message_stop":
                print("🔧 SSE message_stop")

            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let stopReason = delta["stop_reason"] as? String ?? "none"
                    print("🔧 SSE message_delta: stop_reason=\(stopReason)")
                }

            default:
                break
            }
        }

        print("🔧 SSE stream ended — toolUse=\(detectedToolUse != nil ? detectedToolUse!.name : "nil"), textLen=\(fullText.count), blocks=\(assistantContentBlocks.count)")

        // If there's text but it wasn't captured in content_block_stop, add it
        if assistantContentBlocks.isEmpty && !fullText.isEmpty {
            assistantContentBlocks.append(["type": "text", "text": fullText])
        }

        return StreamingPassResult(
            textSoFar: fullText,
            toolUse: detectedToolUse,
            assistantContentBlocks: assistantContentBlocks
        )
    }

    // MARK: - Tool Execution

    private func executeTool(name: String, input: [String: Any]) async throws -> String {
        let searchService = WebSearchService.shared

        switch name {
        case "web_search":
            let query = input["query"] as? String ?? ""
            guard !query.isEmpty else { return "Error: empty search query" }
            let results = try await searchService.searchBrave(query: query)
            return WebSearchService.formatSearchResults(results)

        case "fetch_page":
            let url = input["url"] as? String ?? ""
            guard !url.isEmpty else { return "Error: empty URL" }
            return try await searchService.fetchPage(url: url)

        case "github_search":
            let query = input["query"] as? String ?? ""
            guard !query.isEmpty else { return "Error: empty search query" }
            let language = input["language"] as? String
            let results = try await searchService.searchGitHub(query: query, language: language)
            return WebSearchService.formatGitHubResults(results)

        default:
            return "Unknown tool: \(name)"
        }
    }

    private func parseSSEResponse(data: Data, onChunk: @escaping (String) -> Void) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        var fullResponse = ""

        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { break }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let delta = json["delta"] as? [String: Any],
               let deltaText = delta["text"] as? String {
                fullResponse += deltaText
                DispatchQueue.main.async {
                    onChunk(deltaText)
                }
            }
        }

        return fullResponse
    }
}

