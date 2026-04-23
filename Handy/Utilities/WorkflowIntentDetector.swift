import Foundation

/// Decides whether a normal (non-tutor) guide/help request should have the bounded
/// multi-step workflow capability enabled. This is a **code-side scoring detector**,
/// not just prompt text — the model can still choose to answer normally.
///
/// Decision rule (per spec):
///   Enable workflow capability when:
///     - one strong direct step-by-step trigger is present (Category A), OR
///     - two or more medium UI/procedural triggers are present (Categories B/C/D/E/F)
///       AND the request is clearly actionable (has a verb-ish trigger), OR
///     - an active workflow exists and the user sends a continuation/control phrase (Category G).
///
/// Negative gates (reject when any apply):
///   - pure knowledge question ("what is", "explain", "why does"),
///   - code review / explanation,
///   - free-form writing help,
///   - task clearly needing > 5 steps or long freeform typing.
enum WorkflowIntentDetector {

    // MARK: - Triggers

    /// Category A: direct step-by-step phrases. One match = strong.
    static let directStepPhrases: [String] = [
        "how do i", "how to", "how can i",
        "show me how to", "show me how", "show how",
        "walk me through", "walk through",
        "guide me through", "guide me",
        "teach me how to", "teach me how", "teach me",
        "where do i click", "where do i go", "where should i click",
        "what do i click to", "what do i click next", "what should i click",
        "tell me the steps", "tell me steps",
        "what are the steps", "what's the next step",
        "step by step", "step-by-step",
        "click by click", "click-by-click",
        "one step at a time",
        "take me through it", "take me through this",
        "help me do this", "help me do that",
        "help me set this up", "help me set up",
        "help me configure", "help me configure this",
        "help me install",
        "can you guide me", "can you walk me",
        "can you walk me through", "can you walk me through this",
        "stay with me through", "stay with me",
        "keep guiding me", "continue guiding me",
        "don't stop after the first step", "dont stop after the first step",
        "from start to finish", "end to end",
        "show me the path", "show me where to go",
        "take me there"
    ]

    /// Category B+C+D+E: UI/action/config/dev phrases. Each counts as a medium trigger.
    /// Matched as whole words so we don't pick up "sendemail" in a code paste.
    static let uiActionWords: Set<String> = [
        // B — navigation / discovery
        "open", "navigate", "go", "goto",
        "bring", "pull", "find", "locate", "reveal",
        "expand", "collapse", "switch",
        "dropdown", "submenu", "modal", "dialog", "sidebar", "inspector",
        "panel", "toolbar", "tab", "sheet", "wizard",

        // C — action / activation
        "click", "choose", "select", "pick", "press", "tap",
        "toggle", "enable", "disable", "check", "uncheck",
        "confirm", "apply", "submit", "continue", "finish", "complete",
        "launch", "start", "run", "connect", "authorize",
        "grant", "attach", "upload", "import", "export",
        "share", "send", "save", "publish", "render", "print",
        "duplicate", "rename", "move", "delete", "remove", "archive",

        // D — setup / config / accounts
        "configure", "setup", "signin", "signup", "signout",
        "login", "logout", "install", "uninstall", "onboarding",

        // E — productivity / dev
        "commit", "push", "deploy", "build", "debug", "preview",
        "compile", "simulator", "console", "logs", "debugger",

        // F — UI nouns (count as medium when paired with a verb)
        "menu", "settings", "preferences",
        "button", "checkbox", "toggle", "field", "form",
        "popup", "banner"
    ]

    /// Category G: continuation phrases for an ACTIVE (or recently-active) workflow only.
    static let continuationPhrases: [String] = [
        "next", "continue", "keep going", "go on",
        "what next", "what's next", "whats next", "then what",
        "after that", "now what",
        "what do i do", "what do i do now", "what should i do",
        "what should i do now", "what now",
        "i clicked it", "i clicked", "i did that", "i did it",
        "done", "finished",
        "continue from here", "show next step", "show me next",
        "take me to the next", "take me to the next click",
        "proceed", "next step",
        "the menu is open", "menu is open now", "the menu is open now",
        "with the menu open"
    ]

    /// Negative phrases — reject workflow capability even if other triggers are present.
    static let negativePhrases: [String] = [
        "what is", "what are", "what's", "whats",
        "what does this mean", "what does that mean",
        "explain", "explanation",
        "why does", "why is", "why do", "why did",
        "what do you think",
        "summarize", "summarise", "summary of", "tl;dr", "tldr",
        "brainstorm", "ideas for",
        "write me", "write a", "compose me",
        "draft me",
        "review this code", "review my code", "what does this code",
        "code review", "explain this code"
    ]

    /// Action-ish verbs used to gate the "two or more medium triggers" rule — if none are
    /// present, the request is probably descriptive / conceptual, not actionable.
    static let actionishVerbs: Set<String> = [
        "open", "click", "press", "tap", "choose", "select", "pick",
        "toggle", "enable", "disable", "check", "uncheck",
        "confirm", "apply", "submit", "connect", "share", "send",
        "save", "export", "import", "upload", "publish",
        "configure", "setup", "install", "uninstall",
        "commit", "push", "deploy", "build", "run", "start",
        "launch", "debug", "grant", "authorize",
        "add", "create", "make", "delete", "remove"
    ]

    // MARK: - Decision

    struct Decision: Equatable {
        let shouldEnable: Bool
        let directHits: Int
        let mediumHits: Int
        let isContinuation: Bool
        let reason: String
    }

    /// Evaluate a request. If `workflowActive` is true, continuation phrases alone are enough.
    static func decide(text: String, workflowActive: Bool) -> Decision {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else {
            return Decision(shouldEnable: false, directHits: 0, mediumHits: 0,
                            isContinuation: false, reason: "empty text")
        }

        let tokens = Set(lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })

        // Category G first: continuation phrases while an active workflow exists.
        let continuationMatch = continuationPhrases.contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasSuffix(" " + $0) || lower.contains(" " + $0 + " ") }
        if workflowActive && continuationMatch {
            return Decision(shouldEnable: true, directHits: 0, mediumHits: 0,
                            isContinuation: true, reason: "continuation phrase while workflow active")
        }

        // Negatives: reject knowledge-ish or code-review-ish queries unless a strong direct phrase overrides.
        let hasNegative = negativePhrases.contains { lower.contains($0) }

        // Category A: direct step-by-step phrases.
        var directHits = 0
        for phrase in directStepPhrases {
            if lower.contains(phrase) { directHits += 1 }
        }

        // Category B/C/D/E/F: medium UI/action triggers (whole-word matches).
        let mediumHits = tokens.intersection(uiActionWords).count

        // Actionish presence gates the medium-only rule.
        let hasActionishVerb = !tokens.isDisjoint(with: actionishVerbs)

        // Tighten: the verb that already counts as actionable should NOT double-count as a
        // medium UI trigger. We require at least 2 medium hits *outside* of the actionable
        // verb set, to avoid enabling on "click this button" or "open this dialog".
        let nonVerbMediumHits = tokens.intersection(uiActionWords).subtracting(actionishVerbs).count

        // Very long inputs (e.g. pasted code) — require strong A triggers.
        let isLongInput = lower.count > 400

        if directHits >= 1 {
            if hasNegative && !hasActionishVerb {
                return Decision(shouldEnable: false, directHits: directHits, mediumHits: mediumHits,
                                isContinuation: false,
                                reason: "direct trigger but dominated by knowledge/negative phrasing")
            }
            return Decision(shouldEnable: true, directHits: directHits, mediumHits: mediumHits,
                            isContinuation: false, reason: "direct step-by-step trigger")
        }

        if nonVerbMediumHits >= 2 && hasActionishVerb && !hasNegative && !isLongInput {
            return Decision(shouldEnable: true, directHits: 0, mediumHits: mediumHits,
                            isContinuation: false,
                            reason: "multiple medium UI/procedural triggers + actionable verb")
        }

        return Decision(shouldEnable: false, directHits: directHits, mediumHits: mediumHits,
                        isContinuation: false,
                        reason: "insufficient triggers (negatives or missing actionable verb)")
    }

    /// Convenience boolean alias used by the message pipeline.
    static func shouldEnable(text: String, workflowActive: Bool) -> Bool {
        decide(text: text, workflowActive: workflowActive).shouldEnable
    }
}
