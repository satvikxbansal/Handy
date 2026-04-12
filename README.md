# Handy

A native macOS menu bar assistant that sees your screen, understands context, and guides you with voice + visual pointing. Built in Swift — no Electron.

## Features

- **Screen-aware AI** — Captures your screen and sends it to Claude for context-aware help. The AI sees what you see.
- **Visual pointing** — The assistant can point at specific UI elements on screen with animated cursor overlay using `[POINT:x,y:label]` coordinates.
- **Voice input (STT)** — Push-to-talk via keyboard shortcut. Default: Apple Speech Recognition (on-device when available). Pluggable: OpenAI, AssemblyAI.
- **Voice output (TTS)** — Responses can be spoken aloud. Default: macOS AVSpeechSynthesizer. Optional: ElevenLabs for higher quality.
- **Floating chat panel** — Draggable dark-mode chat interface (~1/4 screen size) with message history, streaming responses, and loading states.
- **Tool/app awareness** — Detects the focused app and window title. Chat history is stored per-tool, so switching apps loads relevant context.
- **Tutor mode** — Toggle in settings. Proactively observes your screen when idle and guides you step-by-step through whatever app you're using. Consumes API tokens.
- **Conversation history** — Stored locally per tool/app. Last 10 turns sent as context to Claude. Scrollable in the chat interface.
- **Secure API key storage** — Keys stored in macOS Keychain. Masked in UI. Never exposed in plaintext files.
- **Multi-monitor support** — Screenshots all displays, labels primary (cursor) screen, maps coordinates correctly across monitors.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Shift + Space` | Start/stop voice input |
| `Shift + Space + O` | Open chat interface |

Custom hotkeys planned for v2.

## Setup

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 16+ for building
- Claude API key from [Anthropic](https://console.anthropic.com/)

### Build & Run

1. Open `Handy.xcodeproj` in Xcode (or build with `swift build` from the `Handy/` directory)
2. Build and run (Cmd+R)
3. Grant permissions when prompted:
   - **Accessibility** (for global hotkeys)
   - **Screen Recording** (for screenshots)
   - **Microphone** (for voice input)
   - **Speech Recognition** (for Apple STT)
4. Click the hand icon in the menu bar, open Settings
5. Add your Claude API key in the **Brain** section
6. Start using: `Shift + Space + O` to open chat, or `Shift + Space` for voice

### API Keys

All keys are stored in macOS Keychain — never in config files or environment variables. Add them in Settings > Brain:

| Provider | Purpose | Required |
|----------|---------|----------|
| **Claude (Anthropic)** | LLM for all AI responses | Yes |
| **OpenAI** | Alternative STT provider | No |
| **AssemblyAI** | Alternative STT provider | No |
| **ElevenLabs** | Higher quality TTS voices | No |

## Architecture

```
Handy/
├── HandyApp.swift              # App entry point (@main)
├── AppDelegate.swift           # Menu bar setup, lifecycle
├── DesignSystem.swift          # DS colors, typography, spacing
├── Info.plist                  # LSUIElement, usage descriptions
├── Handy.entitlements          # Sandbox off, audio/network
├── Models/
│   ├── ChatMessage.swift       # Message + ConversationTurn models
│   ├── AppSettings.swift       # User preferences (mode, providers)
│   └── ScreenCapture.swift     # Screenshot data model
├── Services/
│   ├── HandyManager.swift      # Central orchestrator / state machine
│   ├── ClaudeAPIService.swift  # Anthropic API, SSE streaming
│   ├── ScreenCaptureService.swift  # ScreenCaptureKit multi-display
│   ├── SpeechRecognitionService.swift  # Apple SFSpeechRecognizer
│   ├── TTSService.swift        # AVSpeechSynthesizer + ElevenLabs
│   ├── HotkeyManager.swift     # CGEvent tap global shortcuts
│   ├── ChatHistoryManager.swift    # Per-tool JSON persistence
│   └── OverlayManager.swift    # Transparent pointing overlay
├── Views/
│   ├── ChatPanelManager.swift  # NSPanel floating window
│   ├── ChatInterfaceView.swift # SwiftUI chat + messages
│   └── SettingsView.swift      # Brain / Mode / Trigger tabs
└── Utilities/
    ├── KeychainManager.swift   # Keychain CRUD for API keys
    └── PointParser.swift       # [POINT:x,y:label] parsing + mapping
```

## How It Works

1. **Trigger** — Shift+Space starts voice recording; Shift+Space+O opens the chat panel
2. **Capture** — ScreenCaptureKit takes JPEG screenshots of all displays (max 1280px, 0.8 quality)
3. **Context** — Screenshots + user message + last 10 conversation turns + system prompt sent to Claude
4. **Streaming** — SSE response streams token-by-token into the chat bubble
5. **Pointing** — If Claude includes `[POINT:x,y:label]`, coordinates are mapped from screenshot space to screen space and an animated overlay points at the element
6. **TTS** — Response text (with POINT tags stripped) is spoken via system or ElevenLabs
7. **History** — Conversation turn saved locally, keyed by tool/app name

## Apple Speech Recognition Notes

Handy defaults to Apple's `SFSpeechRecognizer` for STT:

- **On-device mode** available on Apple Silicon Macs (enabled automatically when supported) for lower latency and offline use
- **Server-based mode** used as fallback, requires internet, generally more accurate for complex speech
- **Locale**: Defaults to `en-US`, supports 50+ locales
- **Task hint**: Set to `.dictation` for free-form speech optimization
- **Contextual strings**: Pre-loaded with tech terms (API, Claude, navigate, etc.) for better recognition
- **Limitations**: 1-minute continuous recognition limit per request (Apple-imposed); works best with clear speech in quiet environments

For higher accuracy with technical jargon, switch to OpenAI or AssemblyAI in Settings > Brain.

## License

MIT
