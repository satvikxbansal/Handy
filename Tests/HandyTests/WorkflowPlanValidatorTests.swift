import XCTest
@testable import Handy

final class WorkflowPlanValidatorTests: XCTestCase {

    private func step(_ label: String, _ hint: String, mode: String? = nil) -> WorkflowPlanValidator.RawStep {
        WorkflowPlanValidator.RawStep(
            label: label, hint: hint, expectedRole: nil,
            x: nil, y: nil,
            continuationMode: mode,
            previewDelaySeconds: nil, idleSeconds: nil, maxPreviewDelaySeconds: nil,
            previewMessage: nil
        )
    }

    // MARK: - Accept

    func test_validThreeStepPlan_accepted() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "send an email",
            app: "Gmail",
            steps: [
                step("Compose", "click compose"),
                step("Recipients", "click the to field", mode: "keyboardIdlePreview"),
                step("Send", "click send")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "gmail.com", fromVoice: false)
        guard case .accepted(let plan) = outcome else {
            return XCTFail("expected accepted, got \(outcome)")
        }
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps[1].continuationMode, .keyboardIdlePreview)
    }

    // MARK: - Reject — step count

    func test_oneStepPlan_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "do x", app: "Gmail",
            steps: [step("Send", "click send")]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Gmail", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .wrongStepCount = $0 { return true }; return false })
    }

    func test_sixStepPlan_rejected() {
        let steps = (0..<6).map { step("Step \($0)", "click thing \($0)") }
        let raw = WorkflowPlanValidator.RawPlan(goal: "x", app: "Gmail", steps: steps)
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Gmail", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .wrongStepCount = $0 { return true }; return false })
    }

    // MARK: - Reject — generic labels

    func test_genericLabel_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Xcode",
            steps: [
                step("button", "click the button"),
                step("Send", "click send")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Xcode", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .genericLabel(let i, _) = $0, i == 0 { return true }; return false })
    }

    func test_topLeftLabel_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [
                step("top left", "click top left"),
                step("Export", "click export")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .rejected = outcome else { return XCTFail() }
    }

    // MARK: - Reject — adjacent duplicate label with same hint

    func test_adjacentDuplicate_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [
                step("Export", "click export"),
                step("Export", "click export"),
                step("Done", "click done")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .duplicateAdjacentLabel = $0 { return true }; return false })
    }

    // MARK: - Reject — empty hint

    func test_emptyHint_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [
                step("Compose", ""),
                step("Send", "click send")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .rejected = outcome else { return XCTFail() }
    }

    // MARK: - App mismatch

    func test_appMismatch_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [step("Compose", "click compose"), step("Send", "click send")]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Xcode", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .appMismatch = $0 { return true }; return false })
    }

    func test_looseAppMatch_accepted() {
        // "Gmail" matches "gmail.com" via token intersection.
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Gmail",
            steps: [step("Compose", "click compose"), step("Send", "click send")]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "gmail.com", fromVoice: false)
        XCTAssertTrue(outcome.isAccepted)
    }

    func test_browserUmbrellaLabel_matchesViaContextHints() {
        // Handy's browser tool context is the umbrella label "google.com" but Claude's plan
        // names the visible app "Gmail". A window title hint should make this match.
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Gmail",
            steps: [step("Compose", "click compose"), step("Send", "click send")]
        )
        let outcome = WorkflowPlanValidator.validate(
            raw: raw,
            currentToolName: "google.com",
            contextHints: ["Inbox (12) - foo@gmail.com - Gmail - Google Chrome"],
            fromVoice: false
        )
        XCTAssertTrue(outcome.isAccepted, "Gmail plan should match when window title contains 'Gmail'")
    }

    func test_browserUmbrellaLabel_stillRejectsTrueMismatch() {
        // If neither the tool context nor any hint token matches, rejection should still happen.
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [step("Export", "click export"), step("Save", "click save")]
        )
        let outcome = WorkflowPlanValidator.validate(
            raw: raw,
            currentToolName: "google.com",
            contextHints: ["Inbox - Gmail - Google Chrome"],
            fromVoice: false
        )
        guard case .rejected(let errors) = outcome else { return XCTFail("should reject true mismatch") }
        XCTAssertTrue(errors.contains { if case .appMismatch = $0 { return true }; return false })
    }

    // MARK: - Clamping

    func test_outOfRangePreviewDelay_isClamped() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [
                WorkflowPlanValidator.RawStep(
                    label: "Compose", hint: "click compose",
                    expectedRole: nil, x: nil, y: nil,
                    continuationMode: "fixedDelayPreview",
                    previewDelaySeconds: 99, idleSeconds: 0.1, maxPreviewDelaySeconds: 99,
                    previewMessage: nil
                ),
                step("Send", "click send")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .accepted(let plan) = outcome else { return XCTFail() }
        XCTAssertEqual(plan.steps[0].previewDelaySeconds, WorkflowContinuationPolicy.previewDelayRange.upperBound)
        XCTAssertEqual(plan.steps[0].idleSeconds, WorkflowContinuationPolicy.idleSecondsRange.lowerBound)
        XCTAssertEqual(plan.steps[0].maxPreviewDelaySeconds, WorkflowContinuationPolicy.maxPreviewDelayRange.upperBound)
    }

    // MARK: - Inference

    func test_modeInferred_forTypingHint() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "compose", app: "Gmail",
            steps: [
                step("Body", "type your message here"),
                step("Send", "click send")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Gmail", fromVoice: false)
        guard case .accepted(let plan) = outcome else { return XCTFail() }
        XCTAssertEqual(plan.steps[0].continuationMode, .keyboardIdlePreview)
    }

    func test_modeInferred_forWatchHint() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "export", app: "Figma",
            steps: [
                step("Export", "click export and wait for rendering"),
                step("Download", "click download")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .accepted(let plan) = outcome else { return XCTFail() }
        XCTAssertEqual(plan.steps[0].continuationMode, .fixedDelayPreview)
    }

    // MARK: - Non-immediate cap

    func test_tooManyNonImmediateContinuations_rejected() {
        let raw = WorkflowPlanValidator.RawPlan(
            goal: "x", app: "Figma",
            steps: [
                step("A", "type a", mode: "keyboardIdlePreview"),
                step("B", "type b", mode: "keyboardIdlePreview"),
                step("C", "wait c", mode: "fixedDelayPreview"),
                step("D", "click d")
            ]
        )
        let outcome = WorkflowPlanValidator.validate(raw: raw, currentToolName: "Figma", fromVoice: false)
        guard case .rejected(let errors) = outcome else { return XCTFail() }
        XCTAssertTrue(errors.contains { if case .tooManyNonImmediateContinuations = $0 { return true }; return false })
    }
}
