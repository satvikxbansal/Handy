import Foundation

/// Describes how the NEXT step should be revealed after the current step is clicked.
/// A timer/idle detector may reveal the next click early — it never auto-completes a step.
enum WorkflowContinuationMode: String, Codable, Equatable {
    /// Reveal the next step immediately after the click.
    case immediate
    /// Reveal the next step after a short fixed delay (watch/read/listen/loading style).
    case fixedDelayPreview
    /// Reveal the next step once keyboard activity pauses (typing/entering/pasting style),
    /// or when the max preview delay hits, whichever comes first.
    case keyboardIdlePreview
}

/// A bounded guided workflow — 2 to 5 click-only steps, all resolvable in the current app.
struct GuidedWorkflowPlan: Codable, Equatable {
    /// Stable per-session id (generated locally, not from the model).
    let id: String

    /// One-line user-facing goal (e.g. "send an email in gmail").
    let goal: String

    /// App or site the plan targets (must roughly match the current tool context).
    let app: String

    /// 2...5 steps, each a click target.
    let steps: [GuidedWorkflowStep]

    /// Whether this plan originated from a voice query (controls kickoff narration rules).
    let fromVoice: Bool

    init(
        id: String = UUID().uuidString,
        goal: String,
        app: String,
        steps: [GuidedWorkflowStep],
        fromVoice: Bool
    ) {
        self.id = id
        self.goal = goal
        self.app = app
        self.steps = steps
        self.fromVoice = fromVoice
    }
}
