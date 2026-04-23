import XCTest
@testable import Handy

final class WorkflowIntentDetectorTests: XCTestCase {

    // MARK: - Positive cases (Category A — direct step-by-step)

    func test_directPhrases_enableWorkflow() {
        let positives = [
            "how do i send an email in gmail",
            "walk me through deploying my site",
            "guide me through setting up a new branch",
            "show me how to export a video",
            "teach me how to change the theme",
            "can you guide me through this",
            "take me through it step by step",
            "help me set this up",
            "from start to finish, how do i create an issue"
        ]
        for phrase in positives {
            let decision = WorkflowIntentDetector.decide(text: phrase, workflowActive: false)
            XCTAssertTrue(decision.shouldEnable, "expected enable for: \"\(phrase)\" — reason=\(decision.reason)")
        }
    }

    func test_multipleMediumTriggers_enableWorkflow() {
        // Open + menu + click (3 UI/action tokens) → enables.
        let decision = WorkflowIntentDetector.decide(
            text: "open the settings menu and click sign in",
            workflowActive: false
        )
        XCTAssertTrue(decision.shouldEnable)
        XCTAssertGreaterThanOrEqual(decision.mediumHits, 2)
    }

    // MARK: - Negative cases

    func test_knowledgeQuestions_doNotEnable() {
        let negatives = [
            "what is html",
            "explain flexbox",
            "summarize this article",
            "what does this error mean",
            "why is the sky blue"
        ]
        for phrase in negatives {
            let decision = WorkflowIntentDetector.decide(text: phrase, workflowActive: false)
            XCTAssertFalse(decision.shouldEnable, "expected disable for: \"\(phrase)\"")
        }
    }

    func test_codeReview_doesNotEnable() {
        let decision = WorkflowIntentDetector.decide(
            text: "review this code and tell me what it does",
            workflowActive: false
        )
        XCTAssertFalse(decision.shouldEnable)
    }

    func test_singleButtonMention_doesNotEnable() {
        // Only one medium trigger + no direct phrase + actionable verb present =
        // still 1 medium, not 2 → should not enable.
        let decision = WorkflowIntentDetector.decide(text: "click this button", workflowActive: false)
        XCTAssertFalse(decision.shouldEnable)
    }

    // MARK: - Continuation phrases (Category G)

    func test_continuationPhrases_onlyWhenWorkflowActive() {
        let phrases = ["next", "continue", "keep going", "what next", "i clicked it", "done"]
        for phrase in phrases {
            let inactive = WorkflowIntentDetector.decide(text: phrase, workflowActive: false)
            let active = WorkflowIntentDetector.decide(text: phrase, workflowActive: true)
            XCTAssertFalse(inactive.shouldEnable, "inactive: \"\(phrase)\"")
            XCTAssertTrue(active.shouldEnable, "active: \"\(phrase)\"")
            XCTAssertTrue(active.isContinuation, "active \"\(phrase)\" should be flagged as continuation")
        }
    }

    // MARK: - Mixed / edge

    func test_longPastedCode_doesNotEnableWithoutDirectPhrase() {
        let longCode = String(repeating: "let x = 1; print(x); ", count: 30)
        let decision = WorkflowIntentDetector.decide(
            text: "click this \(longCode)",
            workflowActive: false
        )
        XCTAssertFalse(decision.shouldEnable)
    }
}
