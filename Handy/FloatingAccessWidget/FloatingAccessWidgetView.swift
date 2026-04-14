import SwiftUI

/// Minimal pill: hand when idle/responding/processing; green bars when listening. Drag anywhere; tap opens chat.
struct FloatingAccessWidgetView: View {
    @EnvironmentObject var manager: HandyManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FloatingAccessWidgetMetrics.cornerRadius, style: .continuous)
                .fill(DS.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: FloatingAccessWidgetMetrics.cornerRadius, style: .continuous)
                        .stroke(DS.Colors.border, lineWidth: 1)
                )

            centerContent
                .allowsHitTesting(false)
        }
        .frame(width: FloatingAccessWidgetMetrics.width, height: FloatingAccessWidgetMetrics.height)
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 3)
        .accessibilityLabel("Handy — open chat or drag to move")
    }

    private var accessoryAccent: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.accent.opacity(0.9)
    }

    private var listeningBarFill: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.success
    }

    private var processingTint: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.warning
    }

    @ViewBuilder
    private var centerContent: some View {
        Group {
            switch manager.voiceState {
            case .listening:
                listeningBars
            case .processing:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .tint(processingTint)
            case .idle, .responding:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: FloatingAccessWidgetMetrics.iconSize, weight: .semibold))
                    .foregroundColor(accessoryAccent)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: manager.floatingAccessoryInteractionHighlighted)
    }

    private var listeningBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(listeningBarFill)
                    .frame(width: 2.5, height: 10)
                    .animation(
                        reduceMotion
                            ? .default
                            : .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.12),
                        value: manager.voiceState
                    )
            }
        }
    }
}

enum FloatingAccessWidgetMetrics {
    static let width: CGFloat = 34
    static let height: CGFloat = 38
    static let cornerRadius: CGFloat = 10
    static let iconSize: CGFloat = 14
}
