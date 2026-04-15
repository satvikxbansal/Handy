import SwiftUI

/// Minimal pill: hand when idle/responding; blue waveform when listening (matches companion cursor); blue spinner when processing.
struct FloatingAccessWidgetView: View {
    @EnvironmentObject var manager: HandyManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // No SwiftUI `.shadow` here: it expands into a rectangular layer that often reads as a dull grey box
            // on light backgrounds behind a transparent `NSPanel`. Depth comes from the amber stroke + dark fill.
            RoundedRectangle(cornerRadius: FloatingAccessWidgetMetrics.cornerRadius, style: .continuous)
                .fill(DS.Colors.surface)

            // `strokeBorder` draws inside the shape for uniform weight.
            RoundedRectangle(cornerRadius: FloatingAccessWidgetMetrics.cornerRadius, style: .continuous)
                .strokeBorder(widgetOutlineColor, lineWidth: FloatingAccessWidgetMetrics.outlineWidth)

            centerContent
                .allowsHitTesting(false)
        }
        .frame(width: FloatingAccessWidgetMetrics.width, height: FloatingAccessWidgetMetrics.height)
        .background(Color.clear)
        .accessibilityLabel("Handy — open chat or drag to move")
    }

    private var widgetOutlineColor: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white.opacity(0.95) : DS.Colors.floatingWidgetOutline
    }

    private var accessoryAccent: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.accent.opacity(0.9)
    }

    /// Matches `CompanionWaveformView` / buddy listening — blue bars, not success green.
    private var listeningBarFill: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.overlayCursorBlue
    }

    private var processingStroke: Color {
        manager.floatingAccessoryInteractionHighlighted ? .white : DS.Colors.overlayCursorBlue
    }

    @ViewBuilder
    private var centerContent: some View {
        Group {
            switch manager.voiceState {
            case .listening:
                FloatingWidgetWaveformView(barFill: listeningBarFill, reduceMotion: reduceMotion)
            case .processing:
                FloatingWidgetSpinnerView(strokeColor: processingStroke)
            case .idle, .responding:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: FloatingAccessWidgetMetrics.iconSize, weight: .semibold))
                    .foregroundColor(accessoryAccent)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: manager.floatingAccessoryInteractionHighlighted)
    }
}

// MARK: - Listening (aligned with `CompanionWaveformView`)

private struct FloatingWidgetWaveformView: View {
    let barFill: Color
    let reduceMotion: Bool

    private let barCount = 5
    private let barProfile: [CGFloat] = [0.35, 0.65, 1.0, 0.65, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 36.0)) { context in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(barFill)
                        .frame(width: 2, height: barHeight(for: i, date: context.date))
                }
            }
            .shadow(color: barFill.opacity(0.45), radius: 4, x: 0, y: 0)
        }
    }

    private func barHeight(for index: Int, date: Date) -> CGFloat {
        if reduceMotion {
            return 4 + barProfile[index] * 5
        }
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(index) * 0.35
        let pulse = (sin(phase) + 1) / 2 * 2.8
        let profile = barProfile[index] * 5
        return 3 + profile + pulse
    }
}

// MARK: - Processing (aligned with `CompanionSpinnerView`)

private struct FloatingWidgetSpinnerView: View {
    let strokeColor: Color
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [strokeColor.opacity(0.05), strokeColor],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
            .frame(width: FloatingAccessWidgetMetrics.spinnerSize, height: FloatingAccessWidgetMetrics.spinnerSize)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: strokeColor.opacity(0.5), radius: 4, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

enum FloatingAccessWidgetMetrics {
    static let width: CGFloat = 34
    static let height: CGFloat = 38
    static let cornerRadius: CGFloat = 10
    static let iconSize: CGFloat = 14
    static let spinnerSize: CGFloat = 14
    /// Hairline on @2x/@3x; `strokeBorder` keeps weight even on all sides.
    static let outlineWidth: CGFloat = 1.0
}
