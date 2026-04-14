# Handy

Handy is a native macOS assistant that lives in your menu bar. It looks at your screen, listens when you want it to, and talks back—so you can ask “what do I click?” or “what does this mean?” without pasting screenshots into a separate chat window.

The deeper idea is **context that matches how you actually work**. Most assistants forget that you were just in Xcode and are now in Slack, or that “Chrome” is not the app you care about—the **website** is. Handy tracks the **focused app and site**, keeps **separate conversation memory per place**, and only sends the **recent, relevant thread** to the model along with a fresh view of your displays. Your secrets stay **on your Mac** in the system Keychain; your chat history stays **local files** on disk—not in someone else’s cloud by default.

---

## What makes it different

### Smart app switch (tool context)

When you move from one app to another, you are not having one continuous chat with “the computer”—you are doing different jobs. Handy treats each **focused application** as its own **tool context**. If you were talking about a bug in your editor and then switch to the browser to check docs, the assistant **switches threads** to match: it loads the history and labels for **that** app, not the previous one.

This happens automatically before messages are sent (and when you open the chat panel): the app compares the **current frontmost app** to what it saw last. If you changed apps—or Handy did not yet know a name—it **updates the active tool** and **loads the saved conversation** for that tool. If Handy itself is frontmost (for example you pulled the chat forward), it **does not throw away** your current context just because the menu bar app is active.

Plain English: **one brain, many notebooks**—and it flips to the right notebook when you change what you are working in.

### Website recognition (browsers are not “the tool”)

For a normal Mac app, the tool name is basically the app name. **Browsers are different**: the useful identity is usually the **site or product in the tab**, not “Safari” or “Chrome.”

Handy uses **Accessibility** (with your permission) to read the **URL from the address bar** when it can, derives the **domain**, and maps many common domains to a **short, human label** (for example GitHub, Notion, Figma). If the domain is unfamiliar, it may still use the domain or a **cleaned window title** (without “— Google Chrome” at the end). In some cases it can **enrich** the label with a small vision-assisted step so the “tool” name better matches the **website or product** you are actually using—so the model and the saved history line up with **what is on screen**, not just the browser brand.

### Tool-specific chat memory

Each tool name gets its own **persistent chat history**. That means your thread in **Xcode** does not overwrite your thread for **Linear** or **docs on the web**. When you return to an app, you pick up where you left off for **that** environment.

For each request, only a **recent slice** of that tool’s history (the last several turns) is sent to the AI together with the screenshot and your message—enough for continuity, without dumping your entire past into every call.

### Local storage of context

Conversation turns are stored **on disk** under your user’s Application Support folder, as **JSON per tool**. They are **not** shipped to a Handy server—there isn’t a separate “Handy cloud” for your transcripts in this design. What you keep is **local**, bounded (history per tool is capped), and **keyed by the sanitized tool name** so each context stays separate.

### Local API keys

Provider keys (Claude for the main model, and optional keys for speech or voice providers) are stored in the **macOS Keychain**, not in plain text project files or `.env` on disk. In Settings they can be **masked** in the UI. You bring your own keys; they stay **on your machine** in the same way other serious Mac apps store credentials.

---

## Features (quick list)

- **Screen-aware AI** — Captures your displays and sends them to Claude so help matches what you see.
- **Visual pointing** — Responses can include `[POINT:x,y:label]` so an overlay can **animate toward** a control or region.
- **Voice** — Push-to-talk; default Apple speech (on-device when available); optional OpenAI or AssemblyAI for transcription; system or ElevenLabs for speech output.
- **Floating chat** — Dark, draggable panel with streaming replies and scrollable history.
- **Tutor mode** — Optional mode that watches when you are idle and can nudge you through an app (uses API tokens).
- **Multi-monitor** — Screenshots all displays and maps coordinates sensibly.

---

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `Shift + Space + O` | Open chat |
| `Control + Z` | Start/stop voice input |

Custom hotkeys are planned for a future version.

---

## Setup

### Requirements

- macOS 14.0 (Sonoma) or later  
- Xcode 16+ to build  
- A **Claude API key** from [Anthropic](https://console.anthropic.com/)

### Build and run

1. Open `Handy.xcodeproj` in Xcode (or build from the `Handy/` directory if you use Swift Package Manager workflows).  
2. Build and run (⌘R).  
3. Grant prompts for **Accessibility** (hotkeys and, for browsers, URL reading), **Screen Recording**, **Microphone**, and **Speech Recognition** as needed.  
4. From the menu bar hand icon, open **Settings**.  
5. Under **Brain**, add your **Claude** key (stored in Keychain).  
6. Use **Shift+Space+O** for chat or **Control+Z** for voice.

### API keys (all local)

| Provider | Role | Required |
|----------|------|----------|
| **Anthropic (Claude)** | Main assistant | Yes |
| **OpenAI** | Optional STT | No |
| **AssemblyAI** | Optional STT | No |
| **ElevenLabs** | Optional TTS | No |

Keys are **only** in Keychain from the app’s perspective—not duplicated in repo files.

---

## Architecture

```
Handy/
├── HandyApp.swift              # App entry (@main)
├── AppDelegate.swift           # Menu bar, lifecycle
├── DesignSystem.swift          # Colors, type, spacing
├── Info.plist                  # LSUIElement, usage descriptions
├── Handy.entitlements          # Sandbox off, audio/network
├── Models/
│   ├── ChatMessage.swift
│   ├── AppSettings.swift       # Mode, STT/TTS providers (UserDefaults)
│   └── ScreenCapture.swift
├── Services/
│   ├── HandyManager.swift      # Orchestration, tool switch, browser resolution
│   ├── ClaudeAPIService.swift  # Streaming API
│   ├── ScreenCaptureService.swift  # Multi-display capture, focused app, browser URL
│   ├── SpeechRecognitionService.swift
│   ├── TTSService.swift
│   ├── HotkeyManager.swift
│   ├── ChatHistoryManager.swift    # Per-tool JSON in Application Support
│   └── OverlayManager.swift
├── Views/
│   ├── ChatPanelManager.swift
│   ├── ChatInterfaceView.swift
│   └── SettingsView.swift
└── Utilities/
    ├── KeychainManager.swift
    └── PointParser.swift
```

---

## How a typical request flows

1. **You trigger** voice or open chat.  
2. **Tool resolution** runs: if the focused app changed, Handy **switches tool context** and **loads that tool’s history**. For browsers, it prefers **URL / site identity** over the raw browser name.  
3. **Screenshots** of all displays are taken.  
4. **Claude** receives the images, your message, system instructions, and **recent turns for this tool only**.  
5. **Streaming text** fills the chat; optional **pointing** and **TTS** run on the reply.  
6. The exchange is **appended to local history** for **that tool**.

---

## Apple Speech Recognition notes

Default STT uses `SFSpeechRecognizer`: on Apple Silicon, **on-device** mode is used when available; otherwise server-based recognition. Locale defaults to `en-US`. Apple imposes a **continuous recognition time limit** per session; for heavy jargon, consider OpenAI or AssemblyAI in Settings.

---

## License

MIT
