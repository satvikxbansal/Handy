import Foundation

/// Defaults, clamps, and inference helpers for workflow continuation timing.
///
/// The validator uses these to normalize plans coming back from Claude. The runner
/// also uses them at resolution time if a step still has missing fields.
enum WorkflowContinuationPolicy {

    // MARK: - Clamp ranges

    static let previewDelayRange: ClosedRange<Double> = 1.0...5.0
    static let idleSecondsRange: ClosedRange<Double> = 1.0...3.0
    static let maxPreviewDelayRange: ClosedRange<Double> = 2.0...5.0

    // MARK: - Defaults

    static let defaultPreviewDelaySeconds: Double = 2.5
    static let defaultIdleSeconds: Double = 1.5
    static let defaultMaxPreviewDelaySeconds: Double = 4.0

    // MARK: - Runtime limits (spec: "WORKFLOW RUNTIME LIMITS")

    static let minSteps: Int = 2
    static let maxSteps: Int = 5
    /// Non-immediate continuation steps allowed per workflow.
    static let maxNonImmediateContinuations: Int = 2
    /// Wall-clock lifetime cap.
    static let maxLifetimeSeconds: Double = 120
    /// Initial resolve budget per click step.
    static let maxClickStepResolutionSeconds: Double = 4
    /// Longer budget for delayed-preview resolutions (UI may still be rendering).
    static let maxDelayedPreviewResolutionSeconds: Double = 8
    static let maxRetriesPerBlockedStep: Int = 2
    static let maxConsecutiveUnresolvedSteps: Int = 2
    static let maxPreviewedStepActiveSeconds: Double = 45
    static let antiDoubleClickGraceSeconds: Double = 0.35

    // MARK: - Clamps

    static func clampPreviewDelay(_ value: Double?) -> Double {
        min(max(value ?? defaultPreviewDelaySeconds, previewDelayRange.lowerBound), previewDelayRange.upperBound)
    }

    static func clampIdleSeconds(_ value: Double?) -> Double {
        min(max(value ?? defaultIdleSeconds, idleSecondsRange.lowerBound), idleSecondsRange.upperBound)
    }

    static func clampMaxPreviewDelay(_ value: Double?) -> Double {
        min(max(value ?? defaultMaxPreviewDelaySeconds, maxPreviewDelayRange.lowerBound), maxPreviewDelayRange.upperBound)
    }

    // MARK: - Inference (when model omits `continuationMode`)

    /// Words that hint a user needs to type/enter/paste before the next click.
    static let keyboardIdleCues: Set<String> = [
        "type", "typing", "enter", "entering", "fill", "filling",
        "paste", "pasting", "write", "writing", "search", "searching",
        "prompt", "message", "comment", "caption", "title", "description",
        "recipient", "subject", "body", "note", "form",
        "compose", "draft"
    ]

    /// Words that hint a user needs to watch/read/wait before the next click.
    static let fixedDelayCues: Set<String> = [
        "watch", "watching", "read", "reading", "listen", "listening",
        "review", "reviewing", "inspect", "wait", "waiting",
        "loading", "thinking", "generating", "render", "rendering",
        "upload", "uploading", "processing", "compiling",
        "syncing", "converting", "analyzing", "indexing",
        "transcribing", "download", "downloading"
    ]

    /// Infer a continuation mode from a hint/label if the model didn't supply one.
    static func inferMode(hint: String, label: String = "") -> WorkflowContinuationMode {
        let text = (hint + " " + label).lowercased()
        let tokens = Set(text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })

        if !tokens.isDisjoint(with: keyboardIdleCues) {
            return .keyboardIdlePreview
        }
        if !tokens.isDisjoint(with: fixedDelayCues) {
            return .fixedDelayPreview
        }
        return .immediate
    }

    /// Build a default preview message if the model didn't supply one.
    /// Uses the NEXT step's label so the user knows what to look for.
    static func defaultPreviewMessage(
        mode: WorkflowContinuationMode,
        nextStepLabel: String
    ) -> String {
        let lower = nextStepLabel.lowercased()
        switch mode {
        case .immediate:
            return "next: click \(lower)"
        case .fixedDelayPreview:
            return "when it's ready, click \(lower)"
        case .keyboardIdlePreview:
            return "after you're done, click \(lower)"
        }
    }
}
