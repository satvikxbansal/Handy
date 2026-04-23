import Foundation

/// During an active workflow, certain short phrases should be handled **locally**
/// without round-tripping to Claude. This detector maps typed or transcribed text
/// to a local control action.
enum WorkflowControlAction: Equatable {
    case stop
    case retry
    case skip
    case next
    case resume
    case restartStep
}

enum WorkflowControlPhraseDetector {

    private static let stopPhrases: Set<String> = [
        "stop", "cancel", "never mind", "nevermind", "exit", "quit",
        "stop the workflow", "cancel workflow", "end workflow",
        "stop guiding me", "stop guidance"
    ]

    private static let retryPhrases: Set<String> = [
        "retry", "try again", "try that again", "again", "reload",
        "retry this step", "retry step"
    ]

    private static let skipPhrases: Set<String> = [
        "skip", "skip this", "skip this step", "skip step",
        "move on", "move past this"
    ]

    private static let nextPhrases: Set<String> = [
        "next", "next step", "continue", "keep going", "go on",
        "what next", "what's next", "whats next",
        "i clicked", "i clicked it", "i did that", "i did it",
        "done", "finished",
        "show next step", "show me next", "proceed"
    ]

    private static let resumePhrases: Set<String> = [
        "resume", "pick up where we left off", "continue where we left off",
        "keep going from before"
    ]

    private static let restartStepPhrases: Set<String> = [
        "restart this step", "restart step", "reset this step",
        "start this step over"
    ]

    /// Returns a local action if the text should be handled without calling Claude.
    /// Normalization: lowercase, trim, strip trailing punctuation.
    static func detect(_ rawText: String) -> WorkflowControlAction? {
        let text = normalize(rawText)
        guard !text.isEmpty else { return nil }

        // Short inputs only — a long sentence that happens to contain "next" is NOT a control phrase.
        // Cap at ~8 words to avoid false positives on "I want to go to the next page and then click…".
        let wordCount = text.split(whereSeparator: { $0 == " " }).count
        guard wordCount <= 8 else { return nil }

        if stopPhrases.contains(text) { return .stop }
        if retryPhrases.contains(text) { return .retry }
        if skipPhrases.contains(text) { return .skip }
        if resumePhrases.contains(text) { return .resume }
        if restartStepPhrases.contains(text) { return .restartStep }
        if nextPhrases.contains(text) { return .next }

        // Relaxed prefix match for very short utterances.
        if wordCount <= 3 {
            if text.hasPrefix("stop") { return .stop }
            if text.hasPrefix("cancel") { return .stop }
            if text.hasPrefix("skip") { return .skip }
            if text.hasPrefix("retry") { return .retry }
            if text.hasPrefix("try again") { return .retry }
            if text.hasPrefix("next") { return .next }
            if text.hasPrefix("continue") { return .next }
            if text.hasPrefix("resume") { return .resume }
            if text.hasPrefix("done") { return .next }
        }

        return nil
    }

    private static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'"))
        return stripped
    }
}
