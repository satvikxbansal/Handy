import Foundation

/// One click-only step in a bounded guided workflow.
///
/// Semantic rules:
/// - Every step is a click target.
/// - Timers/idle detection may reveal the next step early, but NEVER auto-complete this step.
/// - Actual workflow progression only happens on a real user click inside the armed target rect.
struct GuidedWorkflowStep: Codable, Equatable, Identifiable {
    /// Stable per-session id.
    let id: String

    /// Visible, semantic label for the clickable control (e.g. "Compose", "Send").
    /// Validator rejects generic labels like "button", "icon", "panel".
    let label: String

    /// Short user-facing instruction shown in the overlay (e.g. "click compose").
    let hint: String

    /// Optional accessibility role hint: button | menu | item | tab | field | toolbaritem | link | checkbox.
    let expectedRole: String?

    /// Optional weak coordinate fallback (screenshot pixel space). Used only if AX resolver fails.
    let hintX: Int?
    let hintY: Int?

    /// How the NEXT step should be revealed once THIS step is clicked.
    /// If nil, `WorkflowContinuationPolicy.inferMode(hint:)` is used.
    let continuationMode: WorkflowContinuationMode?

    /// Used by `.fixedDelayPreview`. Clamped by validator to 1.0...5.0. Default 2.5.
    let previewDelaySeconds: Double?

    /// Used by `.keyboardIdlePreview`. Clamped by validator to 1.0...3.0. Default 1.5.
    let idleSeconds: Double?

    /// Used by `.keyboardIdlePreview`. Clamped by validator to 2.0...5.0. Default 4.0.
    let maxPreviewDelaySeconds: Double?

    /// Short spoken/overlay hint shown while waiting for the next step to reveal
    /// (e.g. "after you're done typing, click send"). Nil = generated default.
    let previewMessage: String?

    init(
        id: String = UUID().uuidString,
        label: String,
        hint: String,
        expectedRole: String? = nil,
        hintX: Int? = nil,
        hintY: Int? = nil,
        continuationMode: WorkflowContinuationMode? = nil,
        previewDelaySeconds: Double? = nil,
        idleSeconds: Double? = nil,
        maxPreviewDelaySeconds: Double? = nil,
        previewMessage: String? = nil
    ) {
        self.id = id
        self.label = label
        self.hint = hint
        self.expectedRole = expectedRole
        self.hintX = hintX
        self.hintY = hintY
        self.continuationMode = continuationMode
        self.previewDelaySeconds = previewDelaySeconds
        self.idleSeconds = idleSeconds
        self.maxPreviewDelaySeconds = maxPreviewDelaySeconds
        self.previewMessage = previewMessage
    }
}
