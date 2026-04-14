import Foundation
import Combine
import AppKit

enum VoiceState: String {
    case idle
    case listening
    case processing
    case responding
}

enum ToolDetectionState {
    case idle
    case detecting
    case detected
    case failed
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

    // MARK: - Element Pointing (observed by CompanionCursorView for fly-to animation)

    /// Global AppKit screen coordinates of a detected UI element the cursor should fly to.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the element is on.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?

    // MARK: - Cursor Overlay Bubbles (voice-only, shown when chat panel is closed)

    /// The user's voice transcript — shown in a yellow bubble near the cursor.
    @Published var overlayTranscriptText: String = ""
    /// The AI's spoken response — shown in a green bubble near the cursor.
    @Published var overlayResponseText: String = ""

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    // MARK: - Tool Detection

    @Published var toolDetectionState: ToolDetectionState = .idle

    // MARK: - Permissions

    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false

    // MARK: - Dependencies

    private let hotkeyManager = HotkeyManager()
    private let speechService = SpeechRecognitionService.shared
    private let ttsService = TTSService.shared
    private let claudeAPI = ClaudeAPIService.shared
    private let historyManager = ChatHistoryManager.shared
    private let companionCursor = CompanionCursorManager()

    // MARK: - Tutor Mode

    private var tutorIdleCancellable: AnyCancellable?
    private var activityMonitor: Any?
    private var idleTimer: Timer?
    private var isTutorObservationInFlight = false
    private var lastUserActivityTime = Date()

    // MARK: - Internal

    @Published var pendingTranscript = ""
    private var loadingTimer: Timer?
    private var currentResponseTask: Task<Void, Never>?
    private var speechRecognitionErrorObserver: AnyCancellable?
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

    /// Chat interface prompt — detailed, helpful written responses.
    private static let chatSystemPrompt = """
    you're handy, a friendly always-on assistant that lives in the user's menu bar. the user typed a message or spoke to you, and you can see their screen. this is an ongoing conversation — you remember previous context.

    rules:
    - give thoughtful, detailed responses. explain the why, not just the what. a few sentences to a short paragraph is ideal — enough to be genuinely useful.
    - if the user asks a simple yes/no question, give the answer then add useful context.
    - all lowercase, casual, warm. no emojis.
    - never say "I can see your screen" or refer to screenshots. just reference what you see naturally, as if you're sitting next to them.
    - you can help with anything — coding, writing, general knowledge, brainstorming, troubleshooting.
    - if the user's question relates to what's on their screen, reference specific things you see — name buttons, labels, menu items.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique. make it something worth coming back for. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at.

    when you point, append a coordinate tag at the very end of your response, AFTER your text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2).

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. the main color board gives you exposure, saturation, and color controls, and you can also use the color wheels for more precise adjustments. if you want finer control, the curves tab lets you adjust individual channels. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language — it's basically the skeleton of every web page. it defines the structure: headings, paragraphs, links, images, forms. browsers read html and render it into the visual page you see. it works hand-in-hand with css for styling and javascript for interactivity. [POINT:none]"
    """

    /// Voice output prompt — ultra-concise spoken part + detailed written part for the chat UI.
    /// The LLM wraps the TTS-bound portion in [SPOKEN]...[/SPOKEN] tags.
    /// Everything outside those tags is shown only in the chat panel.
    private static let voiceSystemPrompt = """
    you're handy, a friendly always-on assistant that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). this is an ongoing conversation — you remember everything they've said before.

    your response has TWO parts:

    1. SPOKEN part — wrapped in [SPOKEN]...[/SPOKEN] tags. this is read aloud via text-to-speech.
       - one sentence, two max. pick the single simplest action the user should take.
       - if there's a button to click, a menu to open, or a shortcut to press — give that ONE action.
       - write for the ear. short, direct, natural. all lowercase, no emojis, no markdown.
       - don't use abbreviations that sound weird aloud. write "for example" not "e.g."
       - never say "simply" or "just". never read code verbatim.
       - for pure knowledge questions with no screen action, give a crisp one-sentence answer.

    2. DETAIL part — everything after [/SPOKEN]. this is shown ONLY in the chat panel (not spoken).
       - explain alternatives, keyboard shortcuts, deeper context, caveats — anything useful beyond the one action you spoke.
       - all lowercase, casual, warm. no emojis. can be a few sentences or a short paragraph.
       - if the spoken answer is complete and there's nothing useful to add, you can skip this part entirely.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. if the spoken action references a specific UI element (button, menu, field), ALWAYS point at it — this makes your help concrete and visual.

    append the POINT tag at the very end of your response (after the detail part, or after [/SPOKEN] if no detail).

    format: [POINT:x,y:label] — x,y are integer pixel coordinates in the screenshot's coordinate space. label is 1-3 words. the origin (0,0) is top-left. x increases rightward, y increases downward. the screenshot images are labeled with their pixel dimensions — use those as the coordinate space.

    if the element is on a DIFFERENT screen than the cursor, append :screenN (e.g. :screen2).
    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to export in figma:
      [SPOKEN]click the share button in the top right, then hit export.[/SPOKEN]
      you can also use command shift e as a shortcut. in the export panel you can pick format — png for images, svg for vector, pdf for print. if you need specific sizes, set the scale before exporting. [POINT:1180,32:share button]

    - user asks what flexbox is:
      [SPOKEN]flexbox is a css layout system that arranges items in a row or column and handles spacing automatically.[/SPOKEN]
      the two key properties are display flex on the container, then justify-content and align-items to control how children are placed. flex-direction switches between row and column. it's way simpler than floats or positioning for most layouts. [POINT:none]

    - user asks how to undo in photoshop:
      [SPOKEN]command z to undo, or command option z to step back through history.[/SPOKEN]
      [POINT:none]
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
    - if the screen hasn't changed since your last observation, say something encouraging or suggest what to click next — don't repeat yourself.

    rules:
    - all lowercase, casual, warm. no emojis. write for spoken delivery.
    - short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
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
        companionCursor.setup(manager: self)
    }

    func start() {
        refreshPermissions()
        if !hasAccessibilityPermission {
            requestAccessibilityPermission()
        }

        let (appName, windowTitle, bundleID) = ScreenCaptureService.focusedAppInfo()
        lastDetectedBundleID = bundleID
        print("🚀 Handy start — app: \"\(appName)\", window: \"\(windowTitle)\", bundle: \(bundleID ?? "nil")")

        if currentToolName.isEmpty && !appName.isEmpty && appName != "Unknown" {
            if ScreenCaptureService.isBrowserBundleID(bundleID) {
                currentToolName = resolveBrowserToolName(appName: appName, windowTitle: windowTitle)
                lastBrowserSiteKey = Self.makeBrowserSiteKey(appName: appName, windowTitle: windowTitle)
            } else {
                currentToolName = appName
                lastBrowserSiteKey = nil
            }
            print("🚀 Initial tool name: \"\(currentToolName)\" siteKey: \(lastBrowserSiteKey ?? "nil")")
        }

        loadCurrentToolContext()
        bindTutorMode()
        startPermissionPolling()
        ScreenCaptureService.startTrackingActiveBrowser()
        bindCompanionCursor()
    }

    func stop() {
        hotkeyManager.stop()
        speechService.stopListening()
        speechRecognitionErrorObserver = nil
        ttsService.stop()
        stopTutorIdleDetection()
        currentResponseTask?.cancel()
        currentResponseTask = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        companionCursor.hide()
    }

    // MARK: - Permission Management

    func refreshPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()

        if hasAccessibilityPermission {
            hotkeyManager.start()
        } else {
            if !previouslyHadAccessibility {
                print("⚠️ Handy: Accessibility NOT granted — hotkeys won't work")
                print("   Go to System Settings > Privacy & Security > Accessibility")
                print("   If Handy is already listed, toggle it OFF then ON (Xcode rebuilds change the code signature)")
            }
            hotkeyManager.stop()
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            print("✅ Handy: Accessibility permission granted — starting hotkey manager")
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

    // MARK: - Companion Cursor

    private func bindCompanionCursor() {
        companionCursor.show()
    }

    // MARK: - Tool Context

    /// The bundle ID of the app that was active when currentToolName was set.
    /// Used to detect when the user switches to a different application.
    /// Never stores Handy's own bundle ID — always tracks the real "target" app.
    private var lastDetectedBundleID: String?

    /// Within Chrome/Safari/etc., the last tab/site we keyed chat history to (e.g. `host:github.com`).
    /// Bundle ID does not change when the user switches tabs, so this is required to switch context.
    private var lastBrowserSiteKey: String?

    private func loadHistoryForTool(_ toolName: String) {
        let history = historyManager.loadHistory(for: toolName)
        messages = history.map { turn in
            [
                ChatMessage(role: .user, content: turn.userMessage, toolName: turn.toolName),
                ChatMessage(role: .assistant, content: turn.assistantMessage, toolName: turn.toolName)
            ]
        }.flatMap { $0 }
    }

    private func loadCurrentToolContext() {
        let (appName, _, _) = ScreenCaptureService.focusedAppInfo()
        let toolName = currentToolName.isEmpty ? appName : currentToolName
        loadHistoryForTool(toolName)
    }

    /// Manually set the tool name (e.g. from the tool name text field in the UI).
    func setToolName(_ name: String) {
        guard name != currentToolName else { return }
        currentToolName = name
        toolDetectionState = .detected

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmostBundleID != Bundle.main.bundleIdentifier {
            lastDetectedBundleID = frontmostBundleID
        }
        if ScreenCaptureService.isBrowserBundleID(frontmostBundleID) {
            let (an, wt, _) = ScreenCaptureService.focusedAppInfo()
            lastBrowserSiteKey = Self.makeBrowserSiteKey(appName: an, windowTitle: wt)
        } else {
            lastBrowserSiteKey = nil
        }

        loadHistoryForTool(name)
    }

    /// Checks the currently focused application and switches tool context if the
    /// user has moved to a different app since the last message. This is the core
    /// of smart tool detection — called before every message is sent.
    ///
    /// For native apps: uses the app name directly (instant).
    /// For browsers: reads the URL via Accessibility to get the domain, then
    /// kicks off async LLM enrichment for a better name.
    ///
    /// Returns the tool name to use for this message.
    private func resolveToolNameWithAutoSwitch() -> String {
        let (appName, windowTitle, bundleID) = ScreenCaptureService.focusedAppInfo()
        print("🔍 resolveToolNameWithAutoSwitch — app: \"\(appName)\", window: \"\(windowTitle)\", bundle: \(bundleID ?? "nil"), lastBundle: \(lastDetectedBundleID ?? "nil"), current: \"\(currentToolName)\"")

        let ownBundleID = Bundle.main.bundleIdentifier
        if bundleID == ownBundleID {
            // Chat panel is key — frontmost app is Handy, not Chrome. Still read the *last active*
            // browser’s address bar (cached PID) so tab/site changes update context and history.
            if let url = ScreenCaptureService.browserURL(),
               let siteKey = ScreenCaptureService.normalizedBrowserSiteKey(from: url),
               let toolFromURL = ScreenCaptureService.umbrellaSiteLabel(from: url) {
                let browserSiteChanged = lastBrowserSiteKey != nil && siteKey != lastBrowserSiteKey
                let needsUpdate = currentToolName.isEmpty || browserSiteChanged || toolFromURL != currentToolName

                if needsUpdate {
                    let previousTool = currentToolName
                    currentToolName = toolFromURL
                    lastBrowserSiteKey = siteKey
                    if let bid = ScreenCaptureService.cachedLastActiveBrowserBundleID() {
                        lastDetectedBundleID = bid
                    }
                    toolDetectionState = .detected

                    if currentToolName != previousTool || browserSiteChanged {
                        if browserSiteChanged {
                            print("🔄 Browser site changed (Handy focused): \"\(previousTool)\" → \"\(currentToolName)\" (site: \(siteKey))")
                        } else {
                            print("🔄 Browser context refreshed (Handy focused): \"\(previousTool)\" → \"\(currentToolName)\"")
                        }
                        loadHistoryForTool(currentToolName)
                    }
                }
            } else {
                print("🔍   Handy is frontmost — no browser URL (last active browser unknown or AX failed)")
            }
            return currentToolName.isEmpty ? appName : currentToolName
        }

        let isBrowser = ScreenCaptureService.isBrowserBundleID(bundleID)
        let siteKey = isBrowser ? Self.makeBrowserSiteKey(appName: appName, windowTitle: windowTitle) : nil

        let appChanged = bundleID != nil && bundleID != lastDetectedBundleID && lastDetectedBundleID != nil
        let browserSiteChanged = isBrowser && siteKey != nil && lastBrowserSiteKey != nil && siteKey != lastBrowserSiteKey

        let needsContextUpdate = currentToolName.isEmpty || appChanged || browserSiteChanged

        if needsContextUpdate {
            let previousTool = currentToolName

            if isBrowser {
                let browserToolName = resolveBrowserToolName(appName: appName, windowTitle: windowTitle)
                currentToolName = browserToolName
            } else {
                currentToolName = appName
                lastBrowserSiteKey = nil
            }

            lastDetectedBundleID = bundleID
            if isBrowser {
                lastBrowserSiteKey = siteKey
            }
            toolDetectionState = .detected

            let historyKeyChanged = currentToolName != previousTool || browserSiteChanged
            if historyKeyChanged {
                if browserSiteChanged {
                    print("🔄 Browser site changed: \"\(previousTool)\" → \"\(currentToolName)\" (site: \(siteKey ?? "nil"))")
                } else {
                    print("🔄 Tool context switched: \"\(previousTool)\" → \"\(currentToolName)\" (bundle: \(bundleID ?? "nil"))")
                }
                loadHistoryForTool(currentToolName)
            }

        } else {
            print("🔍   → No change (same app\(isBrowser ? ", same site \(lastBrowserSiteKey ?? "nil")" : ""))")
        }

        return currentToolName
    }

    /// Identity key for the active browser tab/page (hostname preferred).
    private static func makeBrowserSiteKey(appName: String, windowTitle: String) -> String? {
        if let url = ScreenCaptureService.browserURL(),
           let key = ScreenCaptureService.normalizedBrowserSiteKey(from: url) {
            return key
        }
        let cleaned = cleanBrowserWindowTitle(windowTitle, appName: appName)
        if cleaned.isEmpty { return nil }
        return "title:\(cleaned.lowercased())"
    }

    /// For browsers: one umbrella label per site (path ignored). Never uses window titles (avoids post titles).
    private func resolveBrowserToolName(appName: String, windowTitle: String = "") -> String {
        if let url = ScreenCaptureService.browserURL() {
            print("🌐 Browser URL read via AX: \"\(url)\"")
            if let label = ScreenCaptureService.umbrellaSiteLabel(from: url) {
                print("🌐   → Umbrella site label: \"\(label)\"")
                return label
            }
        } else {
            print("🌐 Browser URL read failed (AX returned nil)")
        }

        // Avoid window titles — they reflect a single tab headline (e.g. X post title).
        print("🌐   → Falling back to browser app name: \"\(appName)\"")
        return appName
    }

    /// Strips the browser suffix from window titles.
    /// "Slack | general - Google Chrome" → "Slack | general"
    /// "GitHub - Google Chrome" → "GitHub"
    private static func cleanBrowserWindowTitle(_ title: String, appName: String) -> String {
        guard !title.isEmpty else { return "" }
        let suffixes = [
            " - Google Chrome", " - Safari", " - Firefox",
            " — Google Chrome", " — Safari", " — Firefox",
            " - Brave", " - Microsoft Edge", " - Arc",
            " — Brave", " — Microsoft Edge", " — Arc",
        ]
        var cleaned = title
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 50 ? String(trimmed.prefix(50)) : trimmed
    }

    /// Called when the chat panel is opened — refresh tool context (incl. browser tab / umbrella site).
    func onChatPanelOpened() {
        let _ = resolveToolNameWithAutoSwitch()
    }

    // MARK: - Send Message

    /// Whether the current message originated from voice input (Control+Z).
    /// Used to select the voice-optimized system prompt for TTS-bound responses.
    private var isCurrentMessageFromVoice = false

    func sendMessage(_ text: String, fromVoice: Bool = false) {
        currentResponseTask?.cancel()
        ttsService.stop()
        isCurrentMessageFromVoice = fromVoice

        let toolName = resolveToolNameWithAutoSwitch()
        let userMsg = ChatMessage(role: .user, content: text, toolName: toolName)
        messages.append(userMsg)

        isProcessing = true
        errorMessage = nil
        streamingText = ""
        startLoadingAnimation()

        currentResponseTask = Task { @MainActor in
            do {
                var images: [(data: Data, label: String)] = []
                var captures: [HandyScreenCapture] = []
                do {
                    captures = try await ScreenCaptureService.captureAllScreens()
                    guard !Task.isCancelled else { return }
                    hasScreenRecordingPermission = true
                    images = captures.map { cap in
                        let dims = " (image dimensions: \(cap.screenshotWidthPx)x\(cap.screenshotHeightPx) pixels)"
                        return (data: cap.imageData, label: cap.label + dims)
                    }
                } catch {
                    let desc = error.localizedDescription.lowercased()
                    let isPermission = error is ScreenCaptureError ||
                        desc.contains("declined") || desc.contains("tcc") ||
                        desc.contains("permission") || desc.contains("denied")

                    if isPermission {
                        hasScreenRecordingPermission = false
                        errorMessage = "Screen Recording permission needed. Toggle Handy OFF then ON in System Settings > Privacy & Security > Screen Recording, then relaunch."
                    }
                    print("⚠️ Screen capture failed, proceeding without screenshots: \(error)")
                }

                let history = historyManager.recentTurns(for: toolName)
                let systemPrompt: String
                if AppSettings.shared.assistantMode == .tutor {
                    systemPrompt = Self.tutorModeSystemPrompt
                } else if fromVoice {
                    systemPrompt = Self.voiceSystemPrompt
                } else {
                    systemPrompt = Self.chatSystemPrompt
                }

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
                        let existing = messages[idx]
                        messages[idx] = ChatMessage(
                            id: existing.id,
                            role: .assistant,
                            content: introPrefix + fullResponse,
                            timestamp: existing.timestamp,
                            toolName: toolName,
                            isStreaming: true
                        )
                    }
                }

                guard !Task.isCancelled else { return }

                let finalText = introPrefix + fullResponse
                stopLoadingAnimation()

                // For voice messages, split into spoken (TTS) and display (chat) parts.
                // For typed messages, the full response is both spoken and displayed.
                let textForTTS: String
                let textForChat: String

                if fromVoice {
                    let rawNoPoints = PointParser.stripPointTags(from: finalText)
                    let parts = PointParser.extractSpokenPart(from: rawNoPoints)
                    textForTTS = parts.spoken
                    textForChat = parts.display
                } else {
                    let cleaned = PointParser.stripPointTags(from: finalText)
                    textForTTS = cleaned
                    textForChat = cleaned
                }

                voiceState = .responding

                if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                    let existing = messages[idx]
                    messages[idx] = ChatMessage(
                        id: existing.id,
                        role: .assistant,
                        content: textForChat,
                        timestamp: existing.timestamp,
                        toolName: toolName,
                        isStreaming: false
                    )
                }

                let turn = ConversationTurn(
                    userMessage: text,
                    assistantMessage: textForChat,
                    timestamp: Date(),
                    toolName: toolName
                )
                historyManager.addTurn(turn, for: toolName)

                let pointResult = PointParser.parse(from: finalText)
                if let coord = pointResult.coordinate, !captures.isEmpty {
                    let targetCapture = captures.first { cap in
                        if let screen = pointResult.screenNumber {
                            return cap.label.contains("screen \(screen)")
                        }
                        return cap.isCursorScreen
                    } ?? captures[0]

                    let globalPoint = PointParser.mapToScreenCoordinates(point: coord, capture: targetCapture)

                    voiceState = .idle

                    detectedElementBubbleText = pointResult.label
                    detectedElementScreenLocation = globalPoint
                    detectedElementDisplayFrame = targetCapture.displayFrame
                }

                // Show overlay bubbles for voice interactions
                if fromVoice {
                    overlayResponseText = textForTTS
                }

                ttsService.speak(textForTTS)

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

                if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    let existing = messages[idx]
                    messages[idx] = ChatMessage(
                        id: existing.id,
                        role: .assistant,
                        content: existing.content.isEmpty ? "(response failed)" : existing.content,
                        timestamp: existing.timestamp,
                        toolName: existing.toolName,
                        isStreaming: false
                    )
                }

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
        overlayTranscriptText = ""
        overlayResponseText = ""

        Task { @MainActor in
            let authorized = await speechService.requestAuthorization()
            guard authorized else {
                errorMessage = "Speech recognition not authorized. Go to System Settings > Privacy & Security > Speech Recognition."
                voiceState = .idle
                return
            }

            do {
                try speechService.startListening { [weak self] transcript, isFinal in
                    guard let self else { return }
                    self.pendingTranscript = transcript
                }

                speechRecognitionErrorObserver = speechService.$error
                    .compactMap { $0 }
                    .receive(on: RunLoop.main)
                    .sink { [weak self] err in
                        guard let self, self.voiceState == .listening else { return }
                        self.errorMessage = err.errorDescription
                        self.speechService.stopListening()
                        self.speechRecognitionErrorObserver = nil
                        self.voiceState = .idle
                    }
            } catch let err as SpeechRecognitionError {
                errorMessage = err.errorDescription
                voiceState = .idle
            } catch {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("siri") && desc.contains("dictation") {
                    errorMessage = SpeechRecognitionError.siriDisabled.errorDescription
                } else {
                    errorMessage = error.localizedDescription
                }
                voiceState = .idle
            }
        }
    }

    func stopVoiceInput() {
        let transcript = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        speechService.stopListening()
        speechRecognitionErrorObserver = nil
        voiceState = .idle

        if !transcript.isEmpty {
            overlayTranscriptText = transcript
            sendMessage(transcript, fromVoice: true)
            pendingTranscript = ""
        }
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

                let toolName = resolveToolNameWithAutoSwitch()
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

                    detectedElementBubbleText = pointResult.label
                    detectedElementScreenLocation = globalPoint
                    detectedElementDisplayFrame = capture.displayFrame
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
        print("🔑 Hotkey triggered: \(action)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch action {
            case .openChat:
                print("🤚 Toggling chat panel...")
                self.chatPanelManager?.toggle()
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
