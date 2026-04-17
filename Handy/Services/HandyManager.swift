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

    /// Incremented when the chat panel is shown after being hidden; `ChatInterfaceView` resets to the main conversation (not Settings).
    @Published private(set) var chatPanelPresentedContentResetNonce: UInt = 0

    /// Hover / click-drag on the floating accessory — white icon vs blue accent.
    @Published private(set) var floatingAccessoryInteractionHighlighted: Bool = false

    func setFloatingAccessoryInteractionHighlighted(_ highlighted: Bool) {
        guard floatingAccessoryInteractionHighlighted != highlighted else { return }
        floatingAccessoryInteractionHighlighted = highlighted
    }

    /// While dragging the floating accessory window, the blue buddy is hidden so it doesn’t overlap the drag.
    @Published private(set) var companionSuppressedForFloatingAccessoryDrag: Bool = false

    func setCompanionSuppressedForFloatingAccessoryDrag(_ suppressed: Bool) {
        guard companionSuppressedForFloatingAccessoryDrag != suppressed else { return }
        companionSuppressedForFloatingAccessoryDrag = suppressed
    }

    // MARK: - Element Pointing (observed by CompanionCursorView for fly-to animation)

    /// Global AppKit screen coordinates of a detected UI element the cursor should fly to.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the element is on.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?

    /// When true, the blue label bubble at the pointer is hidden (voice flows use the green bubble only to avoid overlap).
    @Published var suppressCompanionNavigationLabelBubble: Bool = false

    // MARK: - Cursor Overlay Bubbles (voice-only, shown when chat panel is closed)

    /// The user's voice transcript — shown in a yellow bubble near the cursor.
    @Published var overlayTranscriptText: String = ""
    /// The AI's spoken response — shown in a green bubble near the cursor.
    @Published var overlayResponseText: String = ""

    // MARK: - Web Search Overlay (shown near companion cursor during tool execution)

    /// Brief status text shown in a blue bubble near the cursor while a web search tool is executing.
    /// Empty when no search is in progress.
    @Published var webSearchStatusText: String = ""

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        suppressCompanionNavigationLabelBubble = false
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
    you're handy, a friendly always-on assistant that lives in the user's menu bar on **macos**. the user typed a message or spoke to you, and you can see their screen. this is an ongoing conversation — you remember previous context.

    **platform:** the user is on macos only. never optimize for windows or linux. do not give windows-key shortcuts, "control" shortcuts that are windows-only, or pc-specific menu paths. use standard macos names: menu bar, command, option, control, and mac-appropriate shortcuts.

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
    - if there are several valid ways to do something (click a menu vs keyboard shortcut vs command palette), **lead with the on-screen navigation** — where to go and what to click. put shortcuts and alternate methods after that in a separate short paragraph so the primary path stays unambiguous.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    **critical:** if your answer tells the user to use a **menu bar** item (e.g. terminal, file, edit), open a panel, or click a visible control, you **must** output `[POINT:x,y:label]` targeting that menu or control **in the screenshot image** (small y near the top for menu bar items). do **not** use `[POINT:none]` for those answers unless that part of the ui is genuinely not visible in the screenshots.

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
    you're handy, a friendly always-on assistant that lives in the user's menu bar on **macos**. the user just spoke via push-to-talk and you can see their screen(s). ongoing conversation.

    **platform:** macos only. never give windows/linux shortcuts, win key, or non-mac ui paths. use command, option, control in standard mac combinations.

    your response has TWO parts:

    1. SPOKEN part — wrapped in [SPOKEN]...[/SPOKEN] tags. read aloud via text-to-speech. keep it **very short** (one sentence; two only if unavoidable).
       - for **navigation / where to click** questions: speak **only the primary on-screen path** — the single clearest click or menu journey. do **not** mention keyboard shortcuts, command palettes, or alternate methods here — those go in the detail part only.
       - for questions that are **not** honestly solvable by pointing and a short line (coding tasks, long troubleshooting, policy, or anything needing paragraphs): do **not** try to explain in spoken text. instead use one short line like: "this needs more detail — open handy's chat from the menu bar to read the full answer." (vary wording; stay under one sentence.)
       - for small **general-knowledge** questions with no ui (e.g. what is dns): one crisp spoken sentence is ok.
       - write for the ear. all lowercase, no emojis, no markdown. never read code verbatim. never say "simply" or "just".

    2. DETAIL part — everything after [/SPOKEN]. chat panel only; not spoken.
       - put keyboard shortcuts, command palette tips, alternatives, and deeper steps here. start with the **full click-by-click** path when relevant, then shortcuts in a following sentence.
       - all lowercase, casual, warm. no emojis. if spoken already told the user to open chat for detail, the detail part must still contain the substantive answer for when they read it.

    element pointing:
    you have a small blue triangle cursor that can fly to ui elements. point at the **one** element that matches the **primary on-screen** path you describe in the detail text — usually a menu or button, not a generic area. if a keyboard shortcut exists, still point at the menu item or control it corresponds to when possible.

    append [POINT:x,y:label] at the very end (after detail, or after [/SPOKEN] if no detail).

    format: [POINT:x,y:label] — integer pixel coordinates in the screenshot space; label 1-3 words; origin top-left. if the target is on another screen, append :screenN. if pointing wouldn't help, [POINT:none].

    examples:
    - export in figma (shortcuts only in detail):
      [SPOKEN]click the share button in the top right, then choose export.[/SPOKEN]
      you can also press command shift e. in the export panel pick format — png, svg, or pdf. [POINT:1180,32:share button]

    - conceptual / heavy (redirect spoken; detail has substance):
      [SPOKEN]this needs a longer walkthrough — open handy's chat from the menu bar for the full steps.[/SPOKEN]
      here's how to approach it: … [POINT:none]

    - flexbox (no pointing):
      [SPOKEN]flexbox is css layout for rows and columns with automatic spacing.[/SPOKEN]
      key ideas: display flex, justify-content, align-items, flex-direction… [POINT:none]
    """

    private static let tutorModeSystemPrompt = """
    you're handy in tutor mode on **macos**. the user wants to LEARN whatever software they're currently using. you are their hands-on instructor who can see their screen.

    **platform:** macos only — use mac menus and shortcuts; never assume windows.

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

    /// Builds the system prompt addendum based on which search tools are actually available.
    private static func webSearchPromptAddendum(hasBraveKey: Bool) -> String {
        var tools: [String] = []
        if hasBraveKey { tools.append("web_search") }
        tools.append("fetch_page")
        tools.append("github_search")
        let toolList = tools.joined(separator: ", ")

        var text = "\n\n    web search: you have access to \(toolList) tools."
        if hasBraveKey {
            text += " use them when the user's question needs current or real-time information that your training data might not cover."
        } else {
            text += " you do NOT have web_search (no API key configured) — but you CAN use github_search to find repositories and fetch_page to read any URL directly. for questions needing a general web search, tell the user to add a brave search API key in settings for full web search capability."
        }
        text += " when you use search or fetched results to answer, briefly mention your source naturally (e.g. \"according to the react native docs, the latest version is...\"). in voice responses, just name the source; in chat, you may include a link. do not list raw URLs in spoken responses."
        return text
    }

    /// Whether the user has turned on web search mode.
    /// GitHub search and page reading are free (no key needed), so the toggle alone is enough.
    /// Brave web search requires its own key — if missing, only github_search and fetch_page
    /// are offered to Claude; web_search is excluded from the tool list.
    private var isWebSearchActive: Bool {
        AppSettings.shared.webSearchEnabled
    }

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
        if bundleID != Bundle.main.bundleIdentifier {
            lastNonHandyFrontmostInfo = (appName, windowTitle, bundleID)
        }
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
        startTrackingNonHandyFrontmostApp()
    }

    func stop() {
        if let obs = workspaceActivationObserver {
            NotificationCenter.default.removeObserver(obs)
            workspaceActivationObserver = nil
        }
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

    private func startTrackingNonHandyFrontmostApp() {
        workspaceActivationObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            // Capture the app name and bundle ID directly from the notification's
            // NSRunningApplication — NOT from focusedAppInfo(). The latter re-reads
            // frontmostApplication which, inside a Task hop, could already be a
            // different app (race condition that caused stale "Terminal" tool names).
            let appName = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier
            // Window title still needs AX, read it from the activated app's PID directly.
            var windowTitle = ""
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var windowValue: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
                var titleValue: AnyObject?
                if AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success {
                    windowTitle = titleValue as? String ?? ""
                }
            }
            // Set immediately — no Task hop, no async dispatch. The observer
            // runs on .main queue, so we are on the main thread. assumeIsolated
            // lets us write the @MainActor property synchronously, ensuring the
            // value is available the instant captureAccessoryChatOpenToolSnapshot reads it.
            MainActor.assumeIsolated { [weak self] in
                self?.lastNonHandyFrontmostInfo = (appName, windowTitle, bundleID)
            }
        }
    }

    func noteChatPanelPresentedForMainConversation() {
        chatPanelPresentedContentResetNonce += 1
    }

    /// Call from the floating accessory **before** `ChatPanelManager.show()` (e.g. `mouseDown`), so tool/history match the app the user was in.
    func captureAccessoryChatOpenToolSnapshot() {
        let own = Bundle.main.bundleIdentifier
        let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontBid != own {
            let info = ScreenCaptureService.focusedAppInfo()
            accessoryChatOpenSnapshot = (info.0, info.1, info.2, Date())
            print("📎 Accessory chat open — snapshot from frontmost: \"\(info.0)\" (\(info.2 ?? "nil"))")
            return
        }
        // Handy is already frontmost (clicking widget activated it).
        // Priority: (1) lastNonHandyFrontmostInfo if it matches our last resolved bundle
        //           (2) currentToolName + lastDetectedBundleID from a recent resolved message
        //           (3) lastNonHandyFrontmostInfo even if it doesn't match (best effort)
        // This prevents stale notification data from overwriting a correctly-resolved context.
        if let ext = lastNonHandyFrontmostInfo,
           ext.bundleID == lastDetectedBundleID {
            accessoryChatOpenSnapshot = (ext.appName, ext.windowTitle, ext.bundleID, Date())
            print("📎 Accessory chat open — snapshot from last non-Handy app (matches resolved): \"\(ext.appName)\" (\(ext.bundleID ?? "nil"))")
        } else if !currentToolName.isEmpty, let bid = lastDetectedBundleID {
            accessoryChatOpenSnapshot = (currentToolName, "", bid, Date())
            print("📎 Accessory chat open — snapshot from current tool context: \"\(currentToolName)\" (\(bid))")
        } else if let ext = lastNonHandyFrontmostInfo {
            accessoryChatOpenSnapshot = (ext.appName, ext.windowTitle, ext.bundleID, Date())
            print("📎 Accessory chat open — snapshot from last non-Handy app (fallback): \"\(ext.appName)\" (\(ext.bundleID ?? "nil"))")
        }
    }

    // MARK: - Tool Context

    /// The bundle ID of the app that was active when currentToolName was set.
    /// Used to detect when the user switches to a different application.
    /// Never stores Handy's own bundle ID — always tracks the real "target" app.
    private var lastDetectedBundleID: String?

    /// Within Chrome/Safari/etc., the last tab/site we keyed chat history to (e.g. `host:github.com`).
    /// Bundle ID does not change when the user switches tabs, so this is required to switch context.
    private var lastBrowserSiteKey: String?

    /// Last app the user activated that was not Handy (updated on `NSWorkspace.didActivateApplication`).
    /// Used when the floating accessory is clicked: activation may switch to Handy before we resolve tool context.
    private var lastNonHandyFrontmostInfo: (appName: String, windowTitle: String, bundleID: String?)?

    /// One-shot tool context captured immediately before opening chat from the floating widget (mouseDown).
    /// Consumed by `resolveToolNameWithAutoSwitch()` so behavior matches Shift+Space+O (external app still “logical” focus).
    private var accessoryChatOpenSnapshot: (appName: String, windowTitle: String, bundleID: String?, recorded: Date)?

    private var workspaceActivationObserver: NSObjectProtocol?

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
        let (appName, windowTitle, bundleID) = resolvedFocusedAppInfoForToolSwitch()
        print("🔍 resolveToolNameWithAutoSwitch — app: \"\(appName)\", window: \"\(windowTitle)\", bundle: \(bundleID ?? "nil"), lastBundle: \(lastDetectedBundleID ?? "nil"), current: \"\(currentToolName)\"")

        let ownBundleID = Bundle.main.bundleIdentifier
        if bundleID == ownBundleID {
            // Handy is frontmost (chat panel or widget). Only refresh browser context
            // if the LAST DETECTED APP was a browser. Otherwise a background Chrome
            // would overwrite Xcode/Cursor/etc. context (the root cause of DL-069).
            let lastWasBrowser = ScreenCaptureService.isBrowserBundleID(lastDetectedBundleID)
            if lastWasBrowser,
               let url = ScreenCaptureService.browserURL(),
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
                print("🔍   Handy is frontmost — keeping current context: \"\(currentToolName)\" (lastWasBrowser=\(lastWasBrowser))")
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

    /// Uses a one-shot snapshot from the floating accessory (if present and fresh), else live `focusedAppInfo()`.
    private func resolvedFocusedAppInfoForToolSwitch() -> (appName: String, windowTitle: String, bundleID: String?) {
        if let snap = accessoryChatOpenSnapshot {
            let age = Date().timeIntervalSince(snap.recorded)
            accessoryChatOpenSnapshot = nil
            if age < 1.5 {
                print("🔍 resolveToolName — using accessory snapshot (age \(String(format: "%.2f", age))s)")
                return (snap.appName, snap.windowTitle, snap.bundleID)
            }
        }
        return ScreenCaptureService.focusedAppInfo()
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
        suppressCompanionNavigationLabelBubble = false

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
                var systemPrompt: String
                if AppSettings.shared.assistantMode == .tutor {
                    systemPrompt = Self.tutorModeSystemPrompt
                } else if fromVoice {
                    systemPrompt = Self.voiceSystemPrompt
                } else {
                    systemPrompt = Self.chatSystemPrompt
                }

                let useWebSearch = self.isWebSearchActive
                let hasBraveKey = KeychainManager.hasAPIKey(.braveSearch)
                if useWebSearch {
                    systemPrompt += Self.webSearchPromptAddendum(hasBraveKey: hasBraveKey)
                }

                let introPrefix = messages.count <= 1
                    ? "so we are working with \(toolName), let me help you with your query. "
                    : ""

                let assistantMsg = ChatMessage(role: .assistant, content: "", toolName: toolName, isStreaming: true)
                messages.append(assistantMsg)

                var fullResponse = ""
                voiceState = .processing
                webSearchStatusText = ""
                var collectedSearchTools: [String] = []

                let stream: AsyncThrowingStream<String, Error>
                if useWebSearch {
                    let availableTools = ClaudeAPIService.availableWebSearchTools()
                    stream = claudeAPI.streamResponseWithToolsAsync(
                        userMessage: text,
                        images: images,
                        conversationHistory: history,
                        systemPrompt: systemPrompt,
                        tools: availableTools,
                        onToolUse: { [weak self] searchToolName in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                if !collectedSearchTools.contains(searchToolName) {
                                    collectedSearchTools.append(searchToolName)
                                }
                                switch searchToolName {
                                case "web_search":
                                    self.webSearchStatusText = "Searching the web..."
                                    self.loadingVerb = "Searching the web..."
                                case "github_search":
                                    self.webSearchStatusText = "Searching GitHub..."
                                    self.loadingVerb = "Searching GitHub..."
                                case "fetch_page":
                                    self.webSearchStatusText = "Reading page..."
                                    self.loadingVerb = "Reading page..."
                                default:
                                    self.webSearchStatusText = "Looking things up..."
                                    self.loadingVerb = "Looking things up..."
                                }
                            }
                        }
                    )
                } else {
                    stream = claudeAPI.streamResponseAsync(
                        userMessage: text,
                        images: images,
                        conversationHistory: history,
                        systemPrompt: systemPrompt
                    )
                }

                for try await chunk in stream {
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
                var voiceSpokenUnclamped: String?

                if fromVoice {
                    let rawNoPoints = PointParser.stripPointTags(from: finalText)
                    let parts = PointParser.extractSpokenPart(from: rawNoPoints)
                    let spokenRaw = parts.spoken
                    voiceSpokenUnclamped = spokenRaw
                    textForTTS = PointParser.clampVoiceSpokenForTTS(spokenRaw)
                    // For chat display: if tools were used, the fullResponse has preamble
                    // text ("let me check...") from the first pass. Keep it — it shows the
                    // thought process. But `parts.display` already strips [SPOKEN] tags.
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
                        isStreaming: false,
                        searchToolsUsed: collectedSearchTools
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

                    if fromVoice {
                        suppressCompanionNavigationLabelBubble = true
                    }
                    detectedElementBubbleText = pointResult.label
                    detectedElementScreenLocation = globalPoint
                    detectedElementDisplayFrame = targetCapture.displayFrame
                }

                // Green bubble: shorter cap than TTS so the overlay stays glanceable.
                if fromVoice, let raw = voiceSpokenUnclamped {
                    overlayResponseText = PointParser.clampVoiceSpokenForOverlay(raw)
                }

                // Only speak for push-to-talk replies — typed chat uses the full `chatSystemPrompt` and must not read paragraphs aloud.
                if fromVoice {
                    ttsService.speak(textForTTS)
                }

                isProcessing = false
                streamingText = ""
                voiceState = .idle
                webSearchStatusText = ""

            } catch is CancellationError {
                webSearchStatusText = ""
            } catch {
                stopLoadingAnimation()
                voiceState = .idle
                isProcessing = false
                webSearchStatusText = ""
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
