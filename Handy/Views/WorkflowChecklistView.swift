import SwiftUI

/// Compact inline banner shown above the chat input bar while a guided workflow is active.
///
/// It shows:
/// - the current step index / total
/// - the current step hint
/// - status text from the runner (e.g. "after you're done, click send")
/// - three tiny controls: Retry / Skip / Stop (and optional Resume when suspended)
///
/// Intentionally small — it does NOT redesign any existing UI.
struct WorkflowChecklistView: View {
    @ObservedObject var runner: WorkflowRunner

    var body: some View {
        if let plan = runner.plan, runner.isActive || isTerminalWithLingeringPlan {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                header(plan: plan)
                stepRow(plan: plan)
                if !runner.statusText.isEmpty {
                    Text(runner.statusText)
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                controls
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            .background(DS.Colors.surface)
            .overlay(Rectangle().fill(DS.Colors.accent).frame(width: 2), alignment: .leading)
        }
    }

    private var isTerminalWithLingeringPlan: Bool {
        switch runner.state {
        case .blocked, .suspendedForVoiceQuery:
            return true
        default:
            return false
        }
    }

    private func header(plan: GuidedWorkflowPlan) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accent)
            Text("guiding: \(plan.goal)")
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.accent)
                .lineLimit(1)
            Spacer()
            stateBadge
        }
    }

    private var stateBadge: some View {
        Group {
            switch runner.state {
            case .suspendedForVoiceQuery:
                Text("paused")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
            case .blocked:
                Text("blocked")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.error)
            case .waitingToRevealNext, .previewingNext:
                Text("preview")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.webSearchAccent)
            default:
                EmptyView()
            }
        }
    }

    private func stepRow(plan: GuidedWorkflowPlan) -> some View {
        let current = runner.state.activeStepIndex ?? 0
        return HStack(spacing: DS.Spacing.xs) {
            ForEach(Array(plan.steps.enumerated()), id: \.0) { index, step in
                stepChip(index: index, step: step, current: current)
                if index < plan.steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(DS.Colors.textMuted)
                }
            }
        }
    }

    private func stepChip(index: Int, step: GuidedWorkflowStep, current: Int) -> some View {
        let isActive = index == current
        let isDone = index < current
        return Text(step.label)
            .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            .foregroundColor(isActive ? .white : (isDone ? DS.Colors.textTertiary : DS.Colors.textSecondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? DS.Colors.accent : DS.Colors.surfaceElevated)
            )
    }

    private var controls: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button("Retry") { runner.retryCurrentStep() }
                .buttonStyle(InlineChipStyle(color: DS.Colors.textSecondary))
                .disabled(!canRetryOrSkip)

            Button("Skip") { runner.skipCurrentStep() }
                .buttonStyle(InlineChipStyle(color: DS.Colors.textSecondary))
                .disabled(!canRetryOrSkip)

            if case .suspendedForVoiceQuery = runner.state {
                Button("Resume") { _ = runner.resumeFromVoiceInterrupt() }
                    .buttonStyle(InlineChipStyle(color: DS.Colors.accent))
            }

            Spacer()

            Button("Stop") { runner.stop(reason: .userStop) }
                .buttonStyle(InlineChipStyle(color: DS.Colors.error))
        }
    }

    private var canRetryOrSkip: Bool {
        switch runner.state {
        case .awaitingClick, .previewingNext, .blocked, .waitingToRevealNext:
            return true
        default:
            return false
        }
    }
}

private struct InlineChipStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(configuration.isPressed ? 0.2 : 0.08))
            )
    }
}
