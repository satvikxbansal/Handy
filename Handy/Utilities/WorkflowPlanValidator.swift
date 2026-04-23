import Foundation

/// Validates and normalizes a guided workflow plan that came from Claude's
/// `submit_guided_workflow` tool call.
///
/// Call `validate(raw:...)` which returns either a normalized `GuidedWorkflowPlan`
/// or a list of reasons the plan was rejected. Step-1 resolution is handled
/// separately by the runner.
enum WorkflowPlanValidator {

    // MARK: - Raw shape (from Claude's tool input JSON)

    struct RawStep {
        let label: String
        let hint: String
        let expectedRole: String?
        let x: Int?
        let y: Int?
        let continuationMode: String?
        let previewDelaySeconds: Double?
        let idleSeconds: Double?
        let maxPreviewDelaySeconds: Double?
        let previewMessage: String?
    }

    struct RawPlan {
        let goal: String
        let app: String
        let steps: [RawStep]
    }

    // MARK: - Generic labels we reject outright

    private static let bannedLabels: Set<String> = [
        "button", "icon", "thing", "panel", "element", "control",
        "left side", "right side", "top left", "top right",
        "bottom left", "bottom right",
        "top", "bottom", "center", "middle"
    ]

    private static let uselessHintWords: Set<String> = [
        "click", "press", "tap", "select", "choose", "pick",
        "the", "a", "an", "it", "this", "that", "here"
    ]

    // MARK: - Errors

    enum ValidationError: Error, Equatable {
        case wrongStepCount(Int)
        case appMismatch(planApp: String, currentTool: String)
        case genericLabel(index: Int, label: String)
        case lowInformationHint(index: Int, hint: String)
        case duplicateAdjacentLabel(index: Int, label: String)
        case openEnded
        case longExternalWait
        case tooManyNonImmediateContinuations(count: Int)
        case emptyGoalOrApp
        case invalidStepFields(index: Int, field: String)

        var message: String {
            switch self {
            case .wrongStepCount(let n): return "step count must be 2-5, got \(n)"
            case .appMismatch(let a, let b): return "plan app \"\(a)\" does not match current context \"\(b)\""
            case .genericLabel(let i, let l): return "step \(i + 1) label \"\(l)\" is too generic"
            case .lowInformationHint(let i, let h): return "step \(i + 1) hint \"\(h)\" is empty or too generic"
            case .duplicateAdjacentLabel(let i, let l): return "adjacent duplicate label at step \(i + 1): \"\(l)\""
            case .openEnded: return "plan is open-ended or branches"
            case .longExternalWait: return "plan depends on long external wait"
            case .tooManyNonImmediateContinuations(let c): return "\(c) non-immediate continuations; max is \(WorkflowContinuationPolicy.maxNonImmediateContinuations)"
            case .emptyGoalOrApp: return "goal or app is empty"
            case .invalidStepFields(let i, let field): return "step \(i + 1) has invalid field: \(field)"
            }
        }
    }

    // MARK: - Entry point

    /// Outcome of validation: either a normalized plan or a list of rejection reasons.
    enum Outcome {
        case accepted(GuidedWorkflowPlan)
        case rejected([ValidationError])

        var isAccepted: Bool {
            if case .accepted = self { return true }
            return false
        }
    }

    /// Normalizes and validates. Does NOT attempt step-1 semantic resolution — the runner does that.
    ///
    /// - `currentToolName`: HandyManager-resolved tool name (e.g. "Gmail", "Xcode", "google.com").
    /// - `contextHints`: additional strings used ONLY for app-match (window titles, front app name,
    ///   URL host). This exists because Handy's browser tool context uses umbrella site labels
    ///   (e.g. "google.com") but Claude often names the plan after what's visually on screen
    ///   (e.g. "Gmail"). Including the window title in the match set fixes that collision.
    static func validate(
        raw: RawPlan,
        currentToolName: String,
        contextHints: [String] = [],
        fromVoice: Bool
    ) -> Outcome {
        var errors: [ValidationError] = []

        // Goal + app non-empty
        let goal = raw.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = raw.app.trimmingCharacters(in: .whitespacesAndNewlines)
        if goal.isEmpty || app.isEmpty {
            errors.append(.emptyGoalOrApp)
        }

        // Step count
        let stepCount = raw.steps.count
        if stepCount < WorkflowContinuationPolicy.minSteps || stepCount > WorkflowContinuationPolicy.maxSteps {
            errors.append(.wrongStepCount(stepCount))
        }

        // Loose app match: require any shared alphanumeric token between plan.app and
        // ANY of {currentToolName} ∪ contextHints. This lets "Gmail" match a context whose
        // primary label is "google.com" but whose window title is "Inbox — Gmail — Google Chrome".
        if !app.isEmpty {
            let candidates = ([currentToolName] + contextHints).filter { !$0.isEmpty }
            if !candidates.isEmpty {
                let matched = candidates.contains { appsRoughlyMatch(planApp: app, currentToolName: $0) }
                if !matched {
                    errors.append(.appMismatch(planApp: app, currentTool: currentToolName))
                }
            }
        }

        // Per-step checks
        var normalizedSteps: [GuidedWorkflowStep] = []
        normalizedSteps.reserveCapacity(raw.steps.count)

        for (i, rs) in raw.steps.enumerated() {
            let label = rs.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = rs.hint.trimmingCharacters(in: .whitespacesAndNewlines)

            if label.isEmpty || isBannedLabel(label) {
                errors.append(.genericLabel(index: i, label: label))
            }

            // Hint must have at least one informative token.
            let hintTokens = hint
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let informativeTokens = hintTokens.filter { !uselessHintWords.contains($0) }
            if informativeTokens.isEmpty {
                errors.append(.lowInformationHint(index: i, hint: hint))
            }

            // Duplicate adjacent label (unless hint disambiguates).
            if i > 0 {
                let prev = raw.steps[i - 1]
                let prevLabel = prev.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let curLabel = label.lowercased()
                if !prevLabel.isEmpty && prevLabel == curLabel {
                    let prevHint = prev.hint.lowercased()
                    let curHint = hint.lowercased()
                    if prevHint == curHint {
                        errors.append(.duplicateAdjacentLabel(index: i, label: label))
                    }
                }
            }

            // Normalize continuation fields (clamp ranges + infer mode if missing)
            let inferredMode = WorkflowContinuationPolicy.inferMode(hint: hint, label: label)
            let mode: WorkflowContinuationMode
            if let raw = rs.continuationMode,
               let parsed = WorkflowContinuationMode(rawValue: raw) {
                mode = parsed
            } else {
                mode = inferredMode
            }
            let previewDelay = WorkflowContinuationPolicy.clampPreviewDelay(rs.previewDelaySeconds)
            let idle = WorkflowContinuationPolicy.clampIdleSeconds(rs.idleSeconds)
            let maxPreview = WorkflowContinuationPolicy.clampMaxPreviewDelay(rs.maxPreviewDelaySeconds)

            // Coordinate sanity: both or neither, non-negative if present.
            if (rs.x == nil) != (rs.y == nil) {
                errors.append(.invalidStepFields(index: i, field: "x/y must both be present or both omitted"))
            }
            if let x = rs.x, x < 0 {
                errors.append(.invalidStepFields(index: i, field: "x < 0"))
            }
            if let y = rs.y, y < 0 {
                errors.append(.invalidStepFields(index: i, field: "y < 0"))
            }

            // previewMessage may be empty — that's fine, runner falls back to a default.
            let step = GuidedWorkflowStep(
                label: label,
                hint: hint,
                expectedRole: rs.expectedRole?.trimmingCharacters(in: .whitespacesAndNewlines),
                hintX: rs.x,
                hintY: rs.y,
                continuationMode: mode,
                previewDelaySeconds: previewDelay,
                idleSeconds: idle,
                maxPreviewDelaySeconds: maxPreview,
                previewMessage: rs.previewMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            normalizedSteps.append(step)
        }

        // Non-immediate continuations cap
        let nonImmediateCount = normalizedSteps.filter { ($0.continuationMode ?? .immediate) != .immediate }.count
        if nonImmediateCount > WorkflowContinuationPolicy.maxNonImmediateContinuations {
            errors.append(.tooManyNonImmediateContinuations(count: nonImmediateCount))
        }

        // Open-ended / branching heuristics: goal text contains obvious multi-path cues.
        let lowerGoal = goal.lowercased()
        let branchCues = ["or similar", "either way", "one of these", "whichever", "pick a path"]
        if branchCues.contains(where: { lowerGoal.contains($0) }) {
            errors.append(.openEnded)
        }

        // Long external wait heuristics in hints.
        let waitCues = ["wait for the build", "wait until deployment", "wait for approval", "wait for review"]
        let waitHit = normalizedSteps.contains { step in
            let h = step.hint.lowercased()
            return waitCues.contains { h.contains($0) }
        }
        if waitHit {
            errors.append(.longExternalWait)
        }

        if errors.isEmpty {
            let plan = GuidedWorkflowPlan(
                goal: goal,
                app: app,
                steps: normalizedSteps,
                fromVoice: fromVoice
            )
            return .accepted(plan)
        } else {
            return .rejected(errors)
        }
    }

    // MARK: - Helpers

    private static func isBannedLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        if bannedLabels.contains(trimmed) { return true }
        // Very short (<= 1 char)
        if trimmed.count <= 1 { return true }
        return false
    }

    static func appsRoughlyMatch(planApp: String, currentToolName: String) -> Bool {
        let a = Self.tokens(planApp)
        let b = Self.tokens(currentToolName)
        if a.isEmpty || b.isEmpty { return true } // can't judge — don't block
        return !a.isDisjoint(with: b)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 })
    }
}
