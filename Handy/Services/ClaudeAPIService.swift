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
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
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

    /// Streaming with URLSession delegate for real-time SSE chunks
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
                        "media_type": "image/jpeg",
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
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(self.apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = jsonData

            let delegate = SSEStreamDelegate(continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            task.resume()

            continuation.onTermination = { _ in
                task.cancel()
            }
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

// MARK: - SSE Streaming Delegate

private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer = ""
    private var receivedHTTPResponse = false
    private var httpStatusCode: Int = 0

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        receivedHTTPResponse = true
        httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if httpStatusCode != 200 {
            completionHandler(.allow)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        if httpStatusCode != 200 {
            buffer += chunk
            return
        }

        buffer += chunk

        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { continue }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                continuation.yield(text)
            }

            if let type = json["type"] as? String, type == "message_stop" {
                continuation.finish()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: ClaudeAPIError.networkError(error))
        } else if httpStatusCode != 200 {
            continuation.finish(throwing: ClaudeAPIError.httpError(httpStatusCode, buffer))
        } else {
            continuation.finish()
        }
    }
}
