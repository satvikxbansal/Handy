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

    // MARK: - Guided Workflow

    /// Bounded multi-step guidance runner. Created lazily so tests can substitute fakes if needed.
    /// The runner is completely opt-in: it never runs in tutor mode, and never runs unless a
    /// Claude tool call activates it.
    let workflowRunner: WorkflowRunner = WorkflowRunner()

    /// Captured screen frame (AppKit global coords) for the last plan we accepted,
    /// used only for logging/debugging — not for runtime decisions.
    private var lastAcceptedPlanBundleID: String?

    /// Timestamp of the most recent workflow end. Used to keep continuation phrases
    /// like "what next?" / "what do I do now?" engaged with workflow mode for a short
    /// grace window after the runner ends (e.g. if the user interrupted with a voice follow-up).
    private var lastWorkflowEndedAt: Date?

    /// Holds a non-empty transcript string between the moment `stopVoiceInput` is called
    /// and the moment `sendMessage` is invoked, so the workflow suspend/resume path can
    /// decide correctly based on transcript content.
    private var suspendedWorkflowActive: Bool { workflowRunner.isActive || {
        if case .suspendedForVoiceQuery = workflowRunner.state { return true }
        return false
    }() }

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

    /// Model-facing addendum appended ONLY when WorkflowIntentDetector says this
    /// guide/help request should be allowed to create a bounded click-by-click workflow.
    /// Never appended for tutor mode.
    static let guidedWorkflowPromptAddendum: String = """


    workflow guidance (STRONG PREFERENCE):
    the user just asked something that is a strong candidate for step-by-step guidance. you have TWO response modes:
    1) call submit_guided_workflow(goal, app, steps) for a bounded 2-5 step click-by-click ui workflow — STRONGLY PREFERRED when your answer would naturally list 2 or more clicks
    2) answer normally with one [POINT:x,y:label] — only when a SINGLE click completes the whole task

    decision rule:
    - if you would write "click X, then click Y" → use the workflow tool. always.
    - if you would write "click X" and the user is done → normal answer + one [POINT] is fine.
    - never write a multi-step click path as plain text when the workflow tool is available. the user will not see your text before the next step — they see your pointer. a plain-text list of clicks is the worst option here.

    good fits for the workflow tool:
    - menu / settings / preferences navigation (e.g. change a setting in multiple submenus)
    - compose / create / send flows (e.g. new email, new issue, new branch, publish post)
    - export / share / save-as / download flows
    - setup / configuration / account / permission flows
    - any "how do i X" that requires 2+ distinct on-screen clicks

    plan construction rules:
    - all steps in v1 must be clickable ui targets — typing/watching/waiting steps are still modeled as a click on the field/button that initiates them
    - DO NOT emit a [POINT] tag in the same turn as a workflow tool call
    - first step must be visible on the current screen right now
    - keep labels exact, visible, and specific — copy the actual on-screen label when possible
    - avoid vague labels like "button", "thing", "top left", "right side"
    - keep the workflow short, linear, and bounded; maximum 5 total steps
    - for the plan's "app" field, use whatever name best identifies the CURRENT on-screen context. the validator uses window titles + urls + tool names, so "Gmail" is fine even if the tool context is "google.com".

    for steps that naturally involve typing, reading, watching, listening, waiting for ai output, or waiting for a short loading/rendering state:
    - still model them as click-based steps (click the field, click the button, etc.)
    - set continuationMode for the clicked step so handy can reveal the next click automatically
    - use keyboardIdlePreview for typing / entering / pasting / prompt-box style flows
    - use fixedDelayPreview for watch / read / listen / review / ai-thinking / loading / render / upload / processing style flows
    - preview timing should be short and bounded
    - timers only reveal the next click; they do not mean the user is definitely finished

    if the entire task is ONE click, do not use the workflow tool — a normal answer with one [POINT] is better.
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
        bindWorkflowRunner()
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
                guard let self else { return }
                self.lastNonHandyFrontmostInfo = (appName, windowTitle, bundleID)
                // Stop the workflow if the user switched to a materially different app.
                self.workflowRunner.onAppSwitched(newBundleID: bundleID)
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
        // 0) Workflow short-circuits (tutor mode NEVER enters this path — it doesn't call sendMessage).
        //    The spec: during an active workflow, a local control phrase is handled locally;
        //    any other non-empty message cancels the workflow and proceeds as a normal query.
        let workflowWasActive = workflowRunner.isActive
        if workflowWasActive, AppSettings.shared.assistantMode != .tutor {
            if let action = WorkflowControlPhraseDetector.detect(text) {
                handleWorkflowControlAction(action, originText: text, fromVoice: fromVoice)
                return
            }
            // Typed/voice interruption with a new query → cancel workflow, continue normally.
            workflowRunner.cancel(reason: .typedInterruption)
        }

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

                // Workflow capability: only non-tutor guide/help path. The intent detector
                // is conservative; if it says no, we behave exactly like the current build.
                //
                // We also treat a RECENTLY-cancelled workflow (< 60s ago) as "active" for
                // intent-detection purposes — this lets phrases like "what do I do now?" or
                // "what next?" keep engaging the workflow machinery after the user pressed
                // Control-Z to ask a follow-up mid-flow.
                let recentlyCancelled: Bool = {
                    guard let ts = lastWorkflowEndedAt else { return false }
                    return Date().timeIntervalSince(ts) < 60
                }()
                let intentDecision = WorkflowIntentDetector.decide(
                    text: text,
                    workflowActive: workflowRunner.isActive || recentlyCancelled
                )
                let isTutor = (AppSettings.shared.assistantMode == .tutor)
                let workflowEnabled: Bool = !isTutor && intentDecision.shouldEnable
                if workflowEnabled {
                    systemPrompt += Self.guidedWorkflowPromptAddendum
                }
                print("🧭 sendMessage — text=\"\(text.prefix(120))\" fromVoice=\(fromVoice) tutor=\(isTutor) workflowEnabled=\(workflowEnabled) intent={direct=\(intentDecision.directHits) medium=\(intentDecision.mediumHits) cont=\(intentDecision.isContinuation) reason=\"\(intentDecision.reason)\"}")

                let introPrefix = messages.count <= 1
                    ? "so we are working with \(toolName), let me help you with your query. "
                    : ""

                let assistantMsg = ChatMessage(role: .assistant, content: "", toolName: toolName, isStreaming: true)
                messages.append(assistantMsg)

                var fullResponse = ""
                voiceState = .processing
                webSearchStatusText = ""
                var collectedSearchTools: [String] = []
                let runnerActiveBeforeStream = workflowRunner.isActive

                // Tool list assembled once — may be empty (legacy non-search, non-workflow path).
                let toolsList = ClaudeAPIService.availableTools(
                    webSearchEnabled: useWebSearch,
                    workflowEnabled: workflowEnabled
                )
                let toolNames = toolsList.compactMap { $0["name"] as? String }
                print("🧭 sendMessage — tools=\(toolNames) useWebSearch=\(useWebSearch) currentTool=\"\(toolName)\"")

                // Weak self wrapper for the workflow tool callback (the closure crosses actor hops
                // so we need to hop back to MainActor to talk to the runner).
                var onWorkflowSubmitted: (@Sendable ([String: Any]) async -> String)? = nil
                if workflowEnabled {
                    onWorkflowSubmitted = { [weak self] input in
                        guard let self = self else { return "workflow rejected: handy unavailable" }
                        return await self.handleWorkflowToolCall(input: input, fromVoice: fromVoice)
                    }
                }

                let stream: AsyncThrowingStream<String, Error>
                if !toolsList.isEmpty {
                    stream = claudeAPI.streamResponseWithToolsAsync(
                        userMessage: text,
                        images: images,
                        conversationHistory: history,
                        systemPrompt: systemPrompt,
                        tools: toolsList,
                        onToolUse: { [weak self] searchToolName in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                // submit_guided_workflow is a local tool — don't surface a web-search bubble.
                                if searchToolName == "submit_guided_workflow" { return }
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
                        },
                        onWorkflowSubmitted: onWorkflowSubmitted
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

                // If Claude called submit_guided_workflow in this same turn, the spec says we
                // must ignore any [POINT] tag it emitted — the workflow runner drives pointing.
                let workflowAcceptedThisTurn = workflowRunner.isActive && !runnerActiveBeforeStream
                print("🧭 sendMessage final — workflowAcceptedThisTurn=\(workflowAcceptedThisTurn) runnerState=\(workflowRunner.state) finalTextLen=\(finalText.count)")
                let pointResult = PointParser.parse(from: finalText)
                if !workflowAcceptedThisTurn,
                   let coord = pointResult.coordinate, !captures.isEmpty {
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

                // Green bubble + TTS: suppressed when a workflow was accepted this turn.
                // The WorkflowRunner now owns ALL voice narration and the yellow overlay bubble
                // for the duration of the workflow. Speaking Claude's kickoff here would:
                //   (1) overlap with the runner's "let's go — click X" TTS, and
                //   (2) overwrite the yellow bubble with a green one that says the wrong thing.
                if fromVoice, !workflowAcceptedThisTurn, let raw = voiceSpokenUnclamped {
                    overlayResponseText = PointParser.clampVoiceSpokenForOverlay(raw)
                }

                if fromVoice, !workflowAcceptedThisTurn {
                    let ttsPreview = textForTTS.prefix(150)
                    let hasTags = finalText.contains("[SPOKEN]")
                    print("🔊 TTS — hasSPOKEN=\(hasTags), len=\(textForTTS.count), preview: \"\(ttsPreview)\"")
                    ttsService.speak(textForTTS)
                } else if fromVoice, workflowAcceptedThisTurn {
                    print("🔊 TTS SUPPRESSED — workflow accepted, runner owns voice output")
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

        // Workflow suspend/resume protocol: if a workflow was suspended while listening,
        // empty transcript = resume the workflow, non-empty transcript = cancel + proceed.
        if case .suspendedForVoiceQuery = workflowRunner.state {
            if transcript.isEmpty {
                _ = workflowRunner.resumeFromVoiceInterrupt()
                pendingTranscript = ""
                return
            } else {
                workflowRunner.cancelSuspended(reason: .userNewQuery)
                // fall through to sendMessage as a brand-new query
            }
        }

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

    // MARK: - Guided Workflow Integration

    /// Attach the runner as a presenter (so it can drive the companion-cursor point bubble).
    /// Call once from `start()`.
    fileprivate func bindWorkflowRunner() {
        workflowRunner.attach(presenter: self)

        // When a workflow finishes (any reason), make sure we clear any lingering point bubble
        // and record the end-time so follow-up continuation phrases still engage workflow mode.
        workflowRunner.onEnd
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                guard let self else { return }
                print("🧭 Workflow ended: \(reason)")
                self.clearDetectedElementLocation()
                self.webSearchStatusText = ""
                self.lastWorkflowEndedAt = Date()
            }
            .store(in: &cancellables)
    }

    /// Called by the ClaudeAPIService tool-use loop when Claude emits `submit_guided_workflow`.
    /// Must return the tool_result string synchronously (the caller awaits).
    @MainActor
    func handleWorkflowToolCall(
        input: [String: Any],
        fromVoice: Bool
    ) async -> String {
        print("🧭 handleWorkflowToolCall — fromVoice=\(fromVoice) keys=\(Array(input.keys))")
        // Parse the raw tool input into our validator's RawPlan shape.
        let rawSteps: [WorkflowPlanValidator.RawStep]
        if let stepsArray = input["steps"] as? [[String: Any]] {
            print("🧭   incoming steps count: \(stepsArray.count)")
            rawSteps = stepsArray.map { dict in
                WorkflowPlanValidator.RawStep(
                    label: (dict["label"] as? String) ?? "",
                    hint: (dict["hint"] as? String) ?? "",
                    expectedRole: dict["expectedRole"] as? String,
                    x: (dict["x"] as? Int) ?? (dict["x"] as? NSNumber)?.intValue,
                    y: (dict["y"] as? Int) ?? (dict["y"] as? NSNumber)?.intValue,
                    continuationMode: dict["continuationMode"] as? String,
                    previewDelaySeconds: (dict["previewDelaySeconds"] as? Double)
                        ?? (dict["previewDelaySeconds"] as? NSNumber)?.doubleValue,
                    idleSeconds: (dict["idleSeconds"] as? Double)
                        ?? (dict["idleSeconds"] as? NSNumber)?.doubleValue,
                    maxPreviewDelaySeconds: (dict["maxPreviewDelaySeconds"] as? Double)
                        ?? (dict["maxPreviewDelaySeconds"] as? NSNumber)?.doubleValue,
                    previewMessage: dict["previewMessage"] as? String
                )
            }
        } else {
            return "workflow rejected: missing or invalid steps field"
        }

        let raw = WorkflowPlanValidator.RawPlan(
            goal: (input["goal"] as? String) ?? "",
            app: (input["app"] as? String) ?? currentToolName,
            steps: rawSteps
        )

        // Build context hints so app-match can succeed for browser contexts where the
        // tool name is an umbrella site label (e.g. "google.com") but Claude's plan.app
        // is something visually on-screen (e.g. "Gmail").
        var contextHints: [String] = []
        if let info = lastNonHandyFrontmostInfo {
            contextHints.append(info.appName)
            contextHints.append(info.windowTitle)
        }
        if let url = ScreenCaptureService.browserURL() {
            if let host = ScreenCaptureService.domainFromURL(url) {
                contextHints.append(host)
            }
        }
        print("🧭 handleWorkflowToolCall — currentTool=\"\(currentToolName)\" hints=\(contextHints.filter { !$0.isEmpty })")

        let outcome = WorkflowPlanValidator.validate(
            raw: raw,
            currentToolName: currentToolName,
            contextHints: contextHints,
            fromVoice: fromVoice
        )

        switch outcome {
        case .accepted(let plan):
            print("🧭 Plan validated OK — goal=\"\(plan.goal)\" app=\"\(plan.app)\" steps=\(plan.steps.map { $0.label })")
            // Spec: first step must resolve locally before plan acceptance.
            // Provide the last-non-Handy app's PID so we can resolve even when Handy's chat
            // panel has key focus (common for typed workflows).
            let fallbackPID = workflowFallbackPID()
            let resolver = SemanticElementResolver()
            if let resolved = resolver.resolve(step: plan.steps[0], previousRect: nil, fallbackPID: fallbackPID) {
                print("🧭 Step 1 resolved — rect=\(resolved.globalRect) role=\(resolved.role) matched=\"\(resolved.matchedLabel)\"")
            } else {
                let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                print("🧭 Workflow plan rejected: step 1 not resolvable on screen — \"\(plan.steps[0].label)\" (frontmost=\(frontBid), lastNonHandy=\(lastNonHandyFrontmostInfoBundleID() ?? "nil"), fallbackPID=\(fallbackPID.map { String($0) } ?? "nil"))")
                return "workflow rejected: step 1 (\"\(plan.steps[0].label)\") is not currently visible on screen"
            }

            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                ?? lastDetectedBundleIDExposed()
            workflowRunner.fallbackPIDProvider = { [weak self] in self?.workflowFallbackPID() }
            workflowRunner.start(plan: plan, currentBundleID: bundleID)
            lastAcceptedPlanBundleID = bundleID
            print("🧭 Workflow plan accepted — \(plan.steps.count) steps for \"\(plan.goal)\" runnerState=\(workflowRunner.state)")
            return "workflow accepted: \(plan.steps.count) steps queued for \(plan.app)"

        case .rejected(let errors):
            let reasons = errors.map { $0.message }.joined(separator: "; ")
            print("🧭 Workflow plan rejected: \(reasons)")
            return "workflow rejected: \(reasons)"
        }
    }

    /// Exposed for logging inside the workflow helpers.
    fileprivate func lastNonHandyFrontmostInfoBundleID() -> String? {
        return lastNonHandyFrontmostInfo?.bundleID
    }

    /// PID of the last non-Handy app we saw. Used by the AX resolver so step resolution still
    /// works when Handy's chat panel has key focus (we can't resolve elements in our own UI).
    fileprivate func workflowFallbackPID() -> pid_t? {
        guard let bid = lastNonHandyFrontmostInfo?.bundleID else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid && !$0.isTerminated }) {
            return app.processIdentifier
        }
        return nil
    }

    /// Handle a local control phrase while a workflow is active. No Claude round-trip.
    @MainActor
    fileprivate func handleWorkflowControlAction(
        _ action: WorkflowControlAction,
        originText: String,
        fromVoice: Bool
    ) {
        // Echo the user's command into the chat so they can see what we interpreted.
        let toolName = currentToolName
        let userMsg = ChatMessage(role: .user, content: originText, toolName: toolName)
        messages.append(userMsg)

        let systemNote: String
        switch action {
        case .stop:
            workflowRunner.cancel(reason: .userStop)
            systemNote = "stopped the workflow."
        case .retry:
            workflowRunner.retryCurrentStep()
            systemNote = "retrying the current step."
        case .skip:
            workflowRunner.skipCurrentStep()
            systemNote = "skipping ahead."
        case .next:
            // Already advancing on clicks; acknowledge but don't change state.
            systemNote = "i'm waiting for your click — the next step will reveal itself automatically."
        case .resume:
            if case .suspendedForVoiceQuery = workflowRunner.state {
                _ = workflowRunner.resumeFromVoiceInterrupt()
                systemNote = "resumed the workflow."
            } else {
                systemNote = "nothing to resume — the workflow is already running."
            }
        case .restartStep:
            workflowRunner.retryCurrentStep()
            systemNote = "starting this step over."
        }
        let ack = ChatMessage(role: .assistant, content: systemNote, toolName: toolName)
        messages.append(ack)

        if fromVoice {
            ttsService.speak(systemNote)
        }
    }

    /// Exposes `lastDetectedBundleID` to extension methods (it's private, and we don't want to
    /// change that property's visibility globally).
    fileprivate func lastDetectedBundleIDExposed() -> String? {
        return lastDetectedBundleID
    }
}

// MARK: - WorkflowPointerPresenting

extension HandyManager: WorkflowPointerPresenting {
    func pointAtWorkflowStep(
        globalRect: CGRect,
        label: String,
        previewMessage: String?,
        isPreview: Bool,
        speak: Bool
    ) {
        // Use the existing companion-cursor plumbing: set the target + bubble text.
        // Center the pointer inside the element's rect.
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        // Find the screen containing that point (AppKit global coords).
        let targetFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        detectedElementBubbleText = label
        detectedElementScreenLocation = center
        detectedElementDisplayFrame = targetFrame
        // Voice workflows use the yellow bubble for per-step narration — the blue label
        // bubble near the triangle would fight with it. Hide the blue label so only the
        // yellow narration bubble remains for voice workflows.
        suppressCompanionNavigationLabelBubble = (workflowRunner.plan?.fromVoice ?? false)

        // Build Handy's current narration line.
        //  - For a previewed (future) step, use the previewMessage.
        //  - For an awaiting-click step, use a short "click <label>" line.
        let narrationText: String
        if let msg = previewMessage, !msg.isEmpty {
            narrationText = msg
        } else if !isPreview {
            narrationText = "click \(label.lowercased())"
        } else {
            narrationText = "next: click \(label.lowercased())"
        }

        // Kill any lingering green response bubble BEFORE we set the yellow one, so
        // the companion cursor view doesn't briefly render both overlapping.
        overlayResponseText = ""
        // Force a change notification even if we happen to land on the same string
        // (two consecutive steps could both say "click send" — that would be a no-op).
        if overlayTranscriptText == narrationText {
            overlayTranscriptText = ""
        }
        overlayTranscriptText = PointParser.clampVoiceSpokenForOverlay(narrationText)

        print("🧭 pointAtWorkflowStep — label=\"\(label)\" isPreview=\(isPreview) speak=\(speak) rect=\(globalRect) narration=\"\(narrationText)\"")

        if speak {
            if let msg = previewMessage, !msg.isEmpty {
                print("🔊 Workflow TTS (preview): \"\(msg)\"")
                ttsService.speak(msg)
            } else if !isPreview {
                let kickoff = "let's go — click \(label.lowercased())"
                print("🔊 Workflow TTS (kickoff): \"\(kickoff)\"")
                ttsService.speak(kickoff)
            }
        }
    }

    func clearWorkflowPointer() {
        clearDetectedElementLocation()
        // Also clear the yellow workflow narration so the bubble doesn't linger after completion.
        overlayTranscriptText = ""
        print("🧭 clearWorkflowPointer — cleared detected element + overlay transcript")
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
                    // Stop listening. If a workflow was suspended waiting for this, empty
                    // transcript resumes it and non-empty cancels it (handled in stopVoiceInput).
                    self.stopVoiceInput()
                } else {
                    // If a workflow is currently running, suspend it first. Control-Z during
                    // a running workflow = "interrupt to ask something", per spec.
                    if self.workflowRunner.isActive {
                        _ = self.workflowRunner.suspendForVoiceInterrupt()
                    }
                    self.startVoiceInput()
                }
            }
        }
    }
}
