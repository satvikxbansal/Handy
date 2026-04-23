import Foundation
import CoreGraphics

/// Why a workflow was cancelled / stopped.
enum WorkflowStopReason: Equatable {
    case completed
    case userStop
    case userNewQuery
    case typedInterruption
    case appSwitched
    case lifetimeExceeded
    case tooManyUnresolvedSteps
    case permissionsLost
    case previewUnused
    case blockedGivingUp
    case invalidPlan
    case internalError(String)
}

/// Why a step is blocked.
enum WorkflowBlockReason: Equatable {
    case stepUnresolved
    case retryBudgetExceeded
    case awaitingPreviewTimeout
    case permissionsLost
    case other(String)
}

/// All runtime states a single workflow session can be in.
///
/// Only one session exists at a time (per spec); these states are authoritative
/// and drive what the runner, click detector, activity monitor, and UI do.
enum WorkflowSessionState: Equatable {
    /// No workflow. The runner is not doing anything.
    case idle

    /// Plan being assembled/validated from a Claude tool call.
    case planning

    /// Plan was validated locally; we are confirming step 1 resolves before accepting.
    case validatingPlan

    /// Currently resolving the target for step at the given index.
    case resolvingStep(index: Int)

    /// Step at index is resolved; click detector is armed, waiting for the user to click.
    case awaitingClick(index: Int)

    /// The previous step (at `previousIndex`) was clicked; we are waiting before revealing
    /// the step at `nextIndex` (timer or keyboard-idle based on the previous step's mode).
    case waitingToRevealNext(previousIndex: Int, nextIndex: Int)

    /// The next step is now visible and armed, but we entered it via a delayed preview
    /// (fixedDelayPreview / keyboardIdlePreview) and the user may still be typing/watching.
    /// Progression still requires a real click.
    case previewingNext(index: Int)

    /// Workflow is blocked on step at index. User can Retry / Skip / Stop.
    case blocked(index: Int, reason: WorkflowBlockReason)

    /// Workflow temporarily paused because the user pressed Control-Z to start a voice query.
    /// We remember the state we were in so we can resume if the transcript is empty.
    case suspendedForVoiceQuery(savedState: SavedState)

    /// Terminal: the last step was clicked.
    case completed

    /// Terminal: something stopped the workflow (see `WorkflowStopReason`).
    case cancelled(reason: WorkflowStopReason)

    /// Snapshot of the runner state, used for suspend/resume on Control-Z.
    struct SavedState: Equatable {
        let stepIndex: Int
        /// The state we were in *before* suspension. Encoded as a minimal enum to avoid recursion.
        let priorKind: PriorKind
        /// If we had resolved a click target, this is its last known global rect —
        /// used as a hint so we can re-arm quickly on resume.
        let armedRect: CGRect?
    }

    /// Compact representation of the pre-suspension state (to avoid recursive `indirect` cases).
    enum PriorKind: Equatable {
        case resolvingStep
        case awaitingClick
        case waitingToRevealNext(nextIndex: Int)
        case previewingNext
        case blocked(reason: WorkflowBlockReason)
    }
}

extension WorkflowSessionState {
    /// A concrete step index to render in UI, if any.
    var activeStepIndex: Int? {
        switch self {
        case .idle, .planning, .validatingPlan, .completed, .cancelled, .suspendedForVoiceQuery:
            return nil
        case .resolvingStep(let i), .awaitingClick(let i), .previewingNext(let i), .blocked(let i, _):
            return i
        case .waitingToRevealNext(let prev, _):
            return prev
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .completed, .cancelled: return false
        default: return true
        }
    }
}
