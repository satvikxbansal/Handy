import AppKit
import SwiftUI

/// Manages the blue companion cursor that follows the mouse pointer
/// and reflects voice state (idle triangle, listening waveform, processing spinner).
/// One transparent full-screen window per display, similar to Clicky's OverlayWindow.
@MainActor
final class CompanionCursorManager {
    private var overlayWindows: [CompanionOverlayWindow] = []
    private weak var handyManager: HandyManager?

    func setup(manager: HandyManager) {
        self.handyManager = manager
    }

    func show() {
        guard let manager = handyManager else { return }
        hide()

        for screen in NSScreen.screens {
            let window = CompanionOverlayWindow(screen: screen)

            let cursorView = CompanionCursorView(
                screenFrame: screen.frame,
                manager: manager
            )

            let hostingView = NSHostingView(rootView: cursorView)
            hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = hostingView
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hide() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    var isShowing: Bool { !overlayWindows.isEmpty }
}

// MARK: - Overlay Window

private class CompanionOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Companion Cursor View

struct CompanionCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var manager: HandyManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    @State private var timer: Timer?
    @State private var cursorOpacity: Double = 0.0

    init(screenFrame: CGRect, manager: HandyManager) {
        self.screenFrame = screenFrame
        self.manager = manager
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouse.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 30, y: localY + 22))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouse))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            CompanionTriangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-35))
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.8), radius: 8, x: 0, y: 0)
                .opacity(isCursorOnThisScreen && manager.voiceState == .idle ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.25), value: manager.voiceState)

            CompanionWaveformView()
                .opacity(isCursorOnThisScreen && manager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: manager.voiceState)

            CompanionSpinnerView()
                .opacity(isCursorOnThisScreen && manager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: manager.voiceState)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            startTrackingCursor()
            withAnimation(.easeIn(duration: 0.5)) {
                cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouse = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouse)
            let x = mouse.x - self.screenFrame.origin.x
            let y = self.screenFrame.height - (mouse.y - self.screenFrame.origin.y)
            self.cursorPosition = CGPoint(x: x + 30, y: y + 22)
        }
    }
}

// MARK: - Triangle Shape

private struct CompanionTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// MARK: - Waveform (Listening State)

private struct CompanionWaveformView: View {
    private let barCount = 5
    private let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { context in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(width: 2, height: barHeight(for: i, date: context.date))
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
        }
    }

    private func barHeight(for index: Int, date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(index) * 0.35
        let pulse = (sin(phase) + 1) / 2 * 3.5
        let profile = barProfile[index] * 6
        return 3 + profile + pulse
    }
}

// MARK: - Spinner (Processing State)

private struct CompanionSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}
