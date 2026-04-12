import Foundation
import Combine
import AppKit

enum VoiceState: String {
    case idle
    case listening
    case processing
    case responding
}

/// Central orchestrator. Coordinates hotkeys, voice, screenshots, Claude API,
/// chat history, pointing overlay, and tutor mode.
@MainActor
final class HandyManager: NSObject, ObservableObject {
    static let shared = HandyManager()

    // MARK: - Published State

    @Published var voiceState: VoiceState = .idle
    @Published var messages: [ChatMessage] = []
    @Published var currentToolName: String = ""
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var streamingText = ""
    @Published var loadingVerb = ""

    // MARK: - Permissions

    @Published var hasAccessibilityPermission = false

    // MARK: - Dependencies

    private let hotkeyManager = HotkeyManager()
    private let speechService = SpeechRecognitionService.shared
    private let ttsService = TTSService.shared
    private let claudeAPI = ClaudeAPIService.shared
    private let historyManager = ChatHistoryManager.shared
    private let overlayManager = OverlayManager()

    // MARK: - Tutor Mode

    private var tutorIdleCancellable: AnyCancellable?
    private var activityMonitor: Any?
    private var idleTimer: Timer?
    private var isTutorObservationInFlight = false
    private var lastUserActivityTime = Date()

    // MARK: - Internal

    private var pendingTranscript = ""
    private var loadingTimer: Timer?
    private var currentResponseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    weak var chatPanelManager: ChatPanelManager?

    // MARK: - Loading Verbs (from Claude's action vocabulary)

    private nonisolated static let loadingVerbs = [
        "Analyzing your screen...",
        "Reading the interface...",
        "Scanning for context...",
        "Processing your request...",
        "Understanding the layout...",
        "Examining the elements...",
        "Interpreting what's on screen...",
        "Studying the UI...",
        "Parsing the content...",
        "Mapping the interface...",
        "Evaluating the workspace...",
        "Inspecting the application...",
        "Reviewing the screen...",
        "Decoding the view...",
        "Assessing the context...",
        "Gathering information...",
        "Observing the display...",
        "Surveying the window...",
        "Recognizing elements...",
        "Identifying components...",
        "Synthesizing a response...",
        "Formulating guidance...",
        "Composing an answer...",
        "Piecing it together...",
        "Connecting the dots...",
        "Thinking about this...",
        "Working through it...",
        "Almost there...",
        "Digging deeper...",
        "Looking closely..."
    ]

    // MARK: - System Prompts

    private static let helpModeSystemPrompt = """
    you're handy, a friendly always-on assistant that lives in the user's menu bar. the user spoke to you or typed a message, and you can see their screen. your reply may be spoken aloud via text-to-speech, so write naturally. this is an ongoing conversation — you remember previous context.

    rules:
    - default to one or two sentences. be direct and dense. if the user asks to explain more or elaborate, go deeper with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - never say "I can see your screen" or refer to screenshots. just reference what you see naturally, as if you're sitting next to them.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    when your answer references a specific on-screen element the user should look at or interact with, append a POINT tag at the end of your response. use it when pointing would genuinely help — like showing where a button is, highlighting a menu item, or indicating where to click.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2).

    if pointing wouldn't help, append [POINT:none].

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.
    """

    private static let tutorModeSystemPrompt = """
    you're handy in tutor mode. the user wants to LEARN whatever software they're currently using. you are their hands-on instructor who can see their screen.

    your job:
    - proactively guide them step by step. don't wait to be asked.
    - if they just opened an app, welcome them and suggest where to start.
    - point at buttons, menus, and settings they should interact with. use [POINT] aggressively — a tutor who can point is way more useful than one who just talks.
    - explain WHY, not just what. "click that gear icon — that's where you'll find export settings" is better than "click the gear icon."
    - keep it conversational and encouraging. celebrate small wins.
    - if they seem stuck, offer the next logical step. if they're exploring, let them but add context.

    rules:
    - all lowercase, casual, warm. no emojis. write for spoken delivery.
    - check conversation history to avoid repeating yourself. each observation should build on the last.
    - be specific about what you see — name buttons, labels, menu items.

    element pointing:
    use the same [POINT:x,y:label] format. point at the specific UI element the user should interact with next. if the element is on a different screen, append :screenN.

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.

    if pointing wouldn't help, append [POINT:none].
    """

    // MARK: - Lifecycle

    private override init() {
        super.init()
        hotkeyManager.delegate = self
    }

    func start() {
        refreshPermissions()
        loadCurrentToolContext()
        bindTutorMode()
        startPermissionPolling()
    }

    func stop() {
        hotkeyManager.stop()
        speechService.stopListening()
        ttsService.stop()
        stopTutorIdleDetection()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Permission Management

    func refreshPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()

        if hasAccessibilityPermission {
            hotkeyManager.start()
        } else {
            hotkeyManager.stop()
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            print("✅ Handy: Accessibility permission granted")
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
            }
        }
    }

    // MARK: - Tool Context

    private func loadCurrentToolContext() {
        let (appName, _, _) = ScreenCaptureService.focusedAppInfo()
        let toolName = currentToolName.isEmpty ? appName : currentToolName
        let history = historyManager.loadHistory(for: toolName)
        messages = history.map { turn in
            [
                ChatMessage(role: .user, content: turn.userMessage, toolName: turn.toolName),
                ChatMessage(role: .assistant, content: turn.assistantMessage, toolName: turn.toolName)
            ]
        }.flatMap { $0 }
    }

    func setToolName(_ name: String) {
        guard name != currentToolName else { return }
        currentToolName = name
        loadCurrentToolContext()
    }

    func resolveToolName() -> String {
        if !currentToolName.isEmpty { return currentToolName }
        let (appName, windowTitle, bundleID) = ScreenCaptureService.focusedAppInfo()
        let isBrowser = bundleID?.contains("com.google.Chrome") == true ||
                        bundleID?.contains("com.apple.Safari") == true ||
                        bundleID?.contains("org.mozilla.firefox") == true
        if isBrowser && !windowTitle.isEmpty {
            return windowTitle
        }
        return appName
    }

    // MARK: - Send Message

    func sendMessage(_ text: String) {
        currentResponseTask?.cancel()
        ttsService.stop()

        let toolName = resolveToolName()
        let userMsg = ChatMessage(role: .user, content: text, toolName: toolName)
        messages.append(userMsg)

        isProcessing = true
        errorMessage = nil
        streamingText = ""
        startLoadingAnimation()

        currentResponseTask = Task { @MainActor in
            do {
                let captures = try await ScreenCaptureService.captureAllScreens()
                guard !Task.isCancelled else { return }

                let images = captures.map { cap in
                    let dims = " (image dimensions: \(cap.screenshotWidthPx)x\(cap.screenshotHeightPx) pixels)"
                    return (data: cap.imageData, label: cap.label + dims)
                }

                let history = historyManager.recentTurns(for: toolName)
                let systemPrompt = AppSettings.shared.assistantMode == .tutor
                    ? Self.tutorModeSystemPrompt
                    : Self.helpModeSystemPrompt

                let introPrefix = messages.count <= 1
                    ? "so we are working with \(toolName), let me help you with your query. "
                    : ""

                let assistantMsg = ChatMessage(role: .assistant, content: "", toolName: toolName, isStreaming: true)
                messages.append(assistantMsg)

                var fullResponse = ""
                voiceState = .processing

                for try await chunk in claudeAPI.streamResponseAsync(
                    userMessage: text,
                    images: images,
                    conversationHistory: history,
                    systemPrompt: systemPrompt
                ) {
                    guard !Task.isCancelled else { return }
                    fullResponse += chunk
                    streamingText = introPrefix + fullResponse

                    if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                        messages[idx] = ChatMessage(
                            role: .assistant,
                            content: introPrefix + fullResponse,
                            toolName: toolName,
                            isStreaming: true
                        )
                    }
                }

                guard !Task.isCancelled else { return }

                let finalText = introPrefix + fullResponse
                let cleanedText = PointParser.stripPointTags(from: finalText)
                stopLoadingAnimation()
                voiceState = .responding

                if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                    messages[idx] = ChatMessage(
                        role: .assistant,
                        content: cleanedText,
                        toolName: toolName,
                        isStreaming: false
                    )
                }

                let turn = ConversationTurn(
                    userMessage: text,
                    assistantMessage: cleanedText,
                    timestamp: Date(),
                    toolName: toolName
                )
                historyManager.addTurn(turn, for: toolName)

                let pointResult = PointParser.parse(from: finalText)
                if let coord = pointResult.coordinate {
                    let targetCapture = captures.first { cap in
                        if let screen = pointResult.screenNumber {
                            return cap.label.contains("screen \(screen)")
                        }
                        return cap.isCursorScreen
                    } ?? captures.first!

                    let globalPoint = PointParser.mapToScreenCoordinates(point: coord, capture: targetCapture)
                    overlayManager.pointAt(globalPoint, label: pointResult.label ?? "")
                }

                ttsService.speak(cleanedText)

                isProcessing = false
                streamingText = ""
                voiceState = .idle

            } catch is CancellationError {
                // User sent a new message — interrupted intentionally
            } catch {
                stopLoadingAnimation()
                voiceState = .idle
                isProcessing = false
                errorMessage = error.localizedDescription

                let errorMsg = ChatMessage(role: .system, content: "Error: \(error.localizedDescription)")
                messages.append(errorMsg)
            }
        }
    }

    // MARK: - Voice Input

    func startVoiceInput() {
        guard voiceState == .idle else { return }
        voiceState = .listening
        pendingTranscript = ""

        Task { @MainActor in
            let authorized = await speechService.requestAuthorization()
            guard authorized else {
                errorMessage = "Speech recognition not authorized."
                voiceState = .idle
                return
            }

            do {
                try speechService.startListening { [weak self] transcript, isFinal in
                    guard let self else { return }
                    self.pendingTranscript = transcript
                    if isFinal {
                        self.finishVoiceInput()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                voiceState = .idle
            }
        }
    }

    func stopVoiceInput() {
        speechService.stopListening()
        if !pendingTranscript.isEmpty {
            finishVoiceInput()
        } else {
            voiceState = .idle
        }
    }

    private func finishVoiceInput() {
        speechService.stopListening()
        let transcript = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            voiceState = .idle
            return
        }
        sendMessage(transcript)
    }

    // MARK: - Tutor Mode (idle-triggered observations)

    private func bindTutorMode() {
        AppSettings.shared.$assistantMode
            .sink { [weak self] mode in
                if mode == .tutor {
                    self?.startTutorIdleDetection()
                } else {
                    self?.stopTutorIdleDetection()
                }
            }
            .store(in: &cancellables)
    }

    private func startTutorIdleDetection() {
        stopTutorIdleDetection()

        activityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastUserActivityTime = Date()
            }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      AppSettings.shared.assistantMode == .tutor,
                      self.voiceState == .idle,
                      !self.isTutorObservationInFlight,
                      !self.ttsService.isSpeaking,
                      Date().timeIntervalSince(self.lastUserActivityTime) >= 3.0 else { return }

                self.performTutorObservation()
            }
        }
    }

    private func stopTutorIdleDetection() {
        if let monitor = activityMonitor {
            NSEvent.removeMonitor(monitor)
            activityMonitor = nil
        }
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func performTutorObservation() {
        guard !isTutorObservationInFlight else { return }
        isTutorObservationInFlight = true

        Task { @MainActor in
            defer {
                isTutorObservationInFlight = false
                lastUserActivityTime = Date()
            }

            do {
                let captures = try await ScreenCaptureService.captureFocusedWindow()
                let images = captures.map { cap in
                    let dims = " (image dimensions: \(cap.screenshotWidthPx)x\(cap.screenshotHeightPx) pixels)"
                    return (data: cap.imageData, label: cap.label + dims)
                }

                let toolName = resolveToolName()
                let history = historyManager.recentTurns(for: toolName)

                var fullResponse = ""
                for try await chunk in claudeAPI.streamResponseAsync(
                    userMessage: "observe the screen and guide me",
                    images: images,
                    conversationHistory: history,
                    systemPrompt: Self.tutorModeSystemPrompt
                ) {
                    fullResponse += chunk
                }

                let cleaned = PointParser.stripPointTags(from: fullResponse)
                let assistantMsg = ChatMessage(role: .assistant, content: cleaned, toolName: toolName)
                messages.append(assistantMsg)

                let turn = ConversationTurn(
                    userMessage: "[tutor observation]",
                    assistantMessage: cleaned,
                    timestamp: Date(),
                    toolName: toolName
                )
                historyManager.addTurn(turn, for: toolName)

                let pointResult = PointParser.parse(from: fullResponse)
                if let coord = pointResult.coordinate, let capture = captures.first {
                    let globalPoint = PointParser.mapToScreenCoordinates(point: coord, capture: capture)
                    overlayManager.pointAt(globalPoint, label: pointResult.label ?? "")
                }

                ttsService.speak(cleaned)
            } catch {
                // Tutor observations fail silently — don't interrupt user
            }
        }
    }

    // MARK: - Loading Animation

    private func startLoadingAnimation() {
        loadingVerb = Self.loadingVerbs.randomElement() ?? "Processing..."
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            let verb = Self.loadingVerbs.randomElement() ?? "Processing..."
            Task { @MainActor [weak self] in
                self?.loadingVerb = verb
            }
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingVerb = ""
    }
}

// MARK: - HotkeyManagerDelegate

extension HandyManager: HotkeyManagerDelegate {
    nonisolated func hotkeyTriggered(_ action: HotkeyAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch action {
            case .openChat:
                self.chatPanelManager?.show()
            case .voiceInput:
                if self.voiceState == .listening {
                    self.stopVoiceInput()
                } else {
                    self.startVoiceInput()
                }
            }
        }
    }
}
