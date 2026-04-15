import AppKit
import SwiftUI

/// Manages the blue companion cursor that follows the mouse pointer
/// and reflects voice state (idle triangle, listening waveform, processing spinner).
/// One transparent full-screen window per display. The cursor is always visible
/// and can fly to detected UI elements with a Bezier arc animation.
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

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Navigation Mode

enum BuddyNavigationMode {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

// MARK: - Size Preference Keys

private struct BubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct TranscriptBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct ResponseBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// How long the buddy stays at the target after a successful POINT before flying back.
private enum PointDwellTiming {
    /// Wall-clock time from entering `pointingAtTarget` until the return flight begins (inclusive max 5s).
    static let returnFlightDelayRange: ClosedRange<TimeInterval> = 3.0...5.0
}

// MARK: - Companion Cursor View

struct CompanionCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var manager: HandyManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    @State private var timer: Timer?
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Navigation State

    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor
    @State private var triangleRotationDegrees: Double = -35.0
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero
    @State private var navigationBubbleScale: CGFloat = 1.0
    @State private var buddyFlightScale: CGFloat = 1.0
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero
    @State private var navigationAnimationTimer: Timer?
    @State private var isReturningToCursor: Bool = false
    @State private var pointingReturnWorkItem: DispatchWorkItem?

    // MARK: - Voice Overlay Bubbles State

    @State private var transcriptBubbleOpacity: Double = 0.0
    @State private var transcriptBubbleSize: CGSize = .zero
    @State private var responseBubbleOpacity: Double = 0.0
    @State private var responseBubbleSize: CGSize = .zero
    @State private var responseBubbleStreamedText: String = ""
    @State private var responseBubbleHideTask: DispatchWorkItem?
    @State private var lastShownTranscript: String = ""
    @State private var lastShownResponse: String = ""

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    init(screenFrame: CGRect, manager: HandyManager) {
        self.screenFrame = screenFrame
        self.manager = manager
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouse.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouse))
    }

    // MARK: - Edge-Aware Positioning

    private let edgeMargin: CGFloat = 12

    /// Computes a bubble position that keeps the bubble fully visible within the screen,
    /// flipping horizontally or vertically when the cursor is near edges.
    private func bubblePosition(
        bubbleSize: CGSize,
        preferredXOffset: CGFloat,
        preferredYOffset: CGFloat
    ) -> CGPoint {
        let w = max(bubbleSize.width, 30)
        let h = max(bubbleSize.height, 20)

        let rightX = cursorPosition.x + preferredXOffset + w / 2
        let leftX  = cursorPosition.x - preferredXOffset - w / 2

        let x: CGFloat
        if rightX + w / 2 + edgeMargin > screenFrame.width {
            x = max(edgeMargin + w / 2, leftX)
        } else if leftX - w / 2 < edgeMargin {
            x = min(screenFrame.width - edgeMargin - w / 2, rightX)
        } else {
            x = rightX
        }

        let belowY = cursorPosition.y + abs(preferredYOffset) + h / 2
        let aboveY = cursorPosition.y - abs(preferredYOffset) - h / 2

        let y: CGFloat
        if preferredYOffset >= 0 {
            if belowY + h / 2 + edgeMargin > screenFrame.height {
                y = max(edgeMargin + h / 2, aboveY)
            } else {
                y = belowY
            }
        } else {
            if aboveY - h / 2 < edgeMargin {
                y = min(screenFrame.height - edgeMargin - h / 2, belowY)
            } else {
                y = aboveY
            }
        }

        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            // Navigation pointer bubble — shown when buddy arrives at a detected element (hidden during voice replies to avoid overlapping the green response bubble).
            if !manager.suppressCompanionNavigationLabelBubble
                && buddyNavigationMode == .pointingAtTarget
                && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(bubblePosition(bubbleSize: navigationBubbleSize, preferredXOffset: 10, preferredYOffset: 18))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Yellow transcript bubble — shows what the user said via voice
            if isCursorOnThisScreen && !lastShownTranscript.isEmpty {
                Text(lastShownTranscript)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayTranscriptBubble)
                            .shadow(color: DS.Colors.overlayTranscriptBubble.opacity(0.4), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear.preference(key: TranscriptBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(transcriptBubbleOpacity)
                    .position(bubblePosition(bubbleSize: transcriptBubbleSize, preferredXOffset: 10, preferredYOffset: -12))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.3), value: transcriptBubbleOpacity)
                    .onPreferenceChange(TranscriptBubbleSizePreferenceKey.self) { transcriptBubbleSize = $0 }
            }

            // Green response bubble — shows AI's spoken answer
            if isCursorOnThisScreen && !responseBubbleStreamedText.isEmpty {
                Text(responseBubbleStreamedText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayResponseBubble)
                            .shadow(color: DS.Colors.overlayResponseBubble.opacity(0.4), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear.preference(key: ResponseBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(responseBubbleOpacity)
                    .position(bubblePosition(bubbleSize: responseBubbleSize, preferredXOffset: 10, preferredYOffset: 20))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.3), value: responseBubbleOpacity)
                    .onPreferenceChange(ResponseBubbleSizePreferenceKey.self) { responseBubbleSize = $0 }
            }

            // Blue triangle — visible during idle and responding (TTS playing)
            CompanionTriangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(companionBuddyOpacity(
                    base: buddyIsVisibleOnThisScreen && (manager.voiceState == .idle || manager.voiceState == .responding) ? cursorOpacity : 0
                ))
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: manager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Waveform — replaces triangle while listening
            CompanionWaveformView()
                .opacity(companionBuddyOpacity(
                    base: buddyIsVisibleOnThisScreen && manager.voiceState == .listening ? cursorOpacity : 0
                ))
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: manager.voiceState)

            // Spinner — shown while processing
            CompanionSpinnerView()
                .opacity(companionBuddyOpacity(
                    base: buddyIsVisibleOnThisScreen && manager.voiceState == .processing ? cursorOpacity : 0
                ))
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: manager.voiceState)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)
            let swiftUIPos = convertScreenPointToSwiftUI(mouseLocation)
            cursorPosition = CGPoint(x: swiftUIPos.x + 35, y: swiftUIPos.y + 25)
            startTrackingCursor()
            withAnimation(.easeIn(duration: 0.5)) {
                cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            pointingReturnWorkItem?.cancel()
            pointingReturnWorkItem = nil
        }
        .onChange(of: manager.detectedElementScreenLocation) { newLocation in
            guard let screenLocation = newLocation else { return }
            // Use the mapped target point in global AppKit space — not `displayFrame.midX/Y`.
            // `HandyScreenCapture.displayFrame` can differ slightly from this overlay's `NSScreen.frame`
            // (SCDisplay ↔ NSScreen matching, fallback rects), which caused **no screen** to accept the
            // navigation and the buddy never flew — even when coordinates were valid.
            guard screenFrame.contains(screenLocation) else { return }
            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: manager.overlayTranscriptText) { newText in
            guard !newText.isEmpty else { return }
            lastShownTranscript = newText
            responseBubbleStreamedText = ""
            responseBubbleOpacity = 0.0
            lastShownResponse = ""
            responseBubbleHideTask?.cancel()
            withAnimation { transcriptBubbleOpacity = 1.0 }
        }
        .onChange(of: manager.overlayResponseText) { newText in
            guard !newText.isEmpty else { return }
            lastShownResponse = newText
            withAnimation { transcriptBubbleOpacity = 0.0 }
            streamResponseBubbleText(newText)
        }
        .animation(.easeOut(duration: 0.12), value: manager.companionSuppressedForFloatingAccessoryDrag)
        .onChange(of: manager.voiceState) { newState in
            if newState == .listening {
                responseBubbleHideTask?.cancel()
                responseBubbleHideTask = nil
                withAnimation {
                    transcriptBubbleOpacity = 0.0
                    responseBubbleOpacity = 0.0
                }
                lastShownTranscript = ""
                responseBubbleStreamedText = ""
                lastShownResponse = ""
            }
        }
    }

    /// Hides triangle / waveform / spinner while the floating accessory window is being dragged.
    private func companionBuddyOpacity(base: Double) -> Double {
        manager.companionSuppressedForFloatingAccessoryDrag ? 0 : base
    }

    /// Whether the buddy should be visible on this screen.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if manager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUI(mouseLocation)
                let distanceFromStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            if self.buddyNavigationMode != .followingCursor {
                return
            }

            let swiftUIPos = self.convertScreenPointToSwiftUI(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPos.x + 35, y: swiftUIPos.y + 25)
        }
    }

    private func convertScreenPointToSwiftUI(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    private func startNavigatingToElement(screenLocation: CGPoint) {
        pointingReturnWorkItem?.cancel()
        pointingReturnWorkItem = nil

        let targetInSwiftUI = convertScreenPointToSwiftUI(screenLocation)
        let offsetTarget = CGPoint(x: targetInSwiftUI.x + 8, y: targetInSwiftUI.y + 12)
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUI(mouseLocation)

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination
        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let flightDuration = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDuration / frameInterval)
        var currentFrame = 0

        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            let linearProgress = Double(currentFrame) / Double(totalFrames)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        triangleRotationDegrees = -35.0

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        pointingReturnWorkItem?.cancel()
        let dwell = Double.random(in: PointDwellTiming.returnFlightDelayRange)
        let returnWork = DispatchWorkItem {
            guard self.buddyNavigationMode == .pointingAtTarget else { return }
            self.startFlyingBackToCursor()
        }
        pointingReturnWorkItem = returnWork
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: returnWork)

        // Voice replies use the green bubble for text — skip the blue label; dwell matches the timed return above.
        if manager.suppressCompanionNavigationLabelBubble {
            navigationBubbleOpacity = 0.0
            navigationBubbleScale = 1.0
            return
        }

        let trimmedLabel = manager.detectedElementBubbleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pointerPhrase: String
        if let trimmedLabel, !trimmedLabel.isEmpty {
            pointerPhrase = trimmedLabel
        } else {
            pointerPhrase = navigationPointerPhrases.randomElement() ?? "right here!"
        }

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            withAnimation(.easeOut(duration: 0.3)) {
                self.navigationBubbleOpacity = 0.0
            }
        }
    }

    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    private func startFlyingBackToCursor() {
        pointingReturnWorkItem?.cancel()
        pointingReturnWorkItem = nil

        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUI(mouseLocation)
        let cursorWithOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    private func cancelNavigationAndResumeFollowing() {
        pointingReturnWorkItem?.cancel()
        pointingReturnWorkItem = nil
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    private func finishNavigationAndResumeFollowing() {
        pointingReturnWorkItem?.cancel()
        pointingReturnWorkItem = nil
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        manager.clearDetectedElementLocation()
    }

    // MARK: - Voice Overlay Bubble Helpers

    private func streamResponseBubbleText(_ text: String) {
        responseBubbleStreamedText = ""
        responseBubbleOpacity = 1.0
        responseBubbleHideTask?.cancel()

        var currentIndex = 0
        func streamNext() {
            guard currentIndex < text.count else {
                scheduleResponseBubbleHide()
                return
            }
            let charIndex = text.index(text.startIndex, offsetBy: currentIndex)
            responseBubbleStreamedText.append(text[charIndex])
            currentIndex += 1
            let delay = Double.random(in: 0.02...0.04)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                streamNext()
            }
        }
        streamNext()
    }

    private func scheduleResponseBubbleHide() {
        responseBubbleHideTask?.cancel()
        let work = DispatchWorkItem { [self] in
            withAnimation(.easeOut(duration: 0.5)) {
                self.responseBubbleOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.responseBubbleStreamedText = ""
                self.lastShownResponse = ""
                self.lastShownTranscript = ""
            }
        }
        responseBubbleHideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
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
