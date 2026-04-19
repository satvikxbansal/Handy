import Foundation

enum AppTheme: String, CaseIterable, Codable {
    case dark = "Dark"
    case light = "Light"
}

enum AssistantMode: String, CaseIterable, Codable {
    case helpOnly = "Help Only"
    case tutor = "Tutor"
}

enum STTProvider: String, CaseIterable, Codable {
    case apple = "Apple (Default)"
    case assemblyAI = "AssemblyAI"
    case openAI = "OpenAI"
}

enum TTSProvider: String, CaseIterable, Codable {
    case system = "System (Default)"
    case sarvam = "Sarvam (Bulbul v3)"
}

/// Sarvam Bulbul v3 speaker; `rawValue` is the lowercase API `speaker` parameter.
enum SarvamVoice: String, CaseIterable, Codable {
    case ritu
    case rahul
    case simran

    var pickerTitle: String {
        switch self {
        case .ritu: return "Ritu"
        case .rahul: return "Rahul"
        case .simran: return "Simran"
        }
    }

    var pickerSubtitle: String {
        switch self {
        case .ritu: return "Default"
        case .rahul: return "Male — Composed voice building trust"
        case .simran: return "Female — Warm friendly voice"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var assistantMode: AssistantMode {
        didSet { UserDefaults.standard.set(assistantMode.rawValue, forKey: Keys.assistantMode) }
    }

    @Published var sttProvider: STTProvider {
        didSet { UserDefaults.standard.set(sttProvider.rawValue, forKey: Keys.sttProvider) }
    }

    @Published var ttsProvider: TTSProvider {
        didSet { UserDefaults.standard.set(ttsProvider.rawValue, forKey: Keys.ttsProvider) }
    }

    /// Selected Sarvam speaker when `ttsProvider == .sarvam`. API expects lowercase names (e.g. `ritu`).
    @Published var sarvamVoice: SarvamVoice {
        didSet { UserDefaults.standard.set(sarvamVoice.rawValue, forKey: Keys.sarvamVoice) }
    }

    /// When true, a small draggable pill appears while the chat panel is closed (Settings → Trigger).
    @Published var showFloatingAccessWidget: Bool {
        didSet { UserDefaults.standard.set(showFloatingAccessWidget, forKey: Keys.showFloatingAccessWidget) }
    }

    /// When true, all queries are routed through the web search pipeline (Brave + Jina + GitHub).
    /// Claude receives tool definitions and decides when to search. Requires at least a Brave API key.
    @Published var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: Keys.webSearchEnabled) }
    }

    @Published var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: Keys.appTheme) }
    }

    var isLightMode: Bool { appTheme == .light }

    private enum Keys {
        static let assistantMode = "handy_assistantMode"
        static let sttProvider = "handy_sttProvider"
        static let ttsProvider = "handy_ttsProvider"
        static let sarvamVoice = "handy_sarvamVoice"
        static let showFloatingAccessWidget = "handy_showFloatingAccessWidget"
        static let webSearchEnabled = "handy_webSearchEnabled"
        static let appTheme = "handy_appTheme"
    }

    private init() {
        KeychainManager.migrateLegacyElevenLabsKeyToSarvamIfNeeded()

        let modeRaw = UserDefaults.standard.string(forKey: Keys.assistantMode) ?? AssistantMode.helpOnly.rawValue
        self.assistantMode = AssistantMode(rawValue: modeRaw) ?? .helpOnly

        let sttRaw = UserDefaults.standard.string(forKey: Keys.sttProvider) ?? STTProvider.apple.rawValue
        self.sttProvider = STTProvider(rawValue: sttRaw) ?? .apple

        var ttsRaw = UserDefaults.standard.string(forKey: Keys.ttsProvider) ?? TTSProvider.system.rawValue
        // Former ElevenLabs option maps to Sarvam so users keep a cloud TTS slot in Settings.
        if ttsRaw == "ElevenLabs" {
            ttsRaw = TTSProvider.sarvam.rawValue
            UserDefaults.standard.set(ttsRaw, forKey: Keys.ttsProvider)
        }
        self.ttsProvider = TTSProvider(rawValue: ttsRaw) ?? .system

        let voiceRaw = UserDefaults.standard.string(forKey: Keys.sarvamVoice) ?? SarvamVoice.ritu.rawValue
        self.sarvamVoice = SarvamVoice(rawValue: voiceRaw) ?? .ritu

        self.showFloatingAccessWidget = UserDefaults.standard.object(forKey: Keys.showFloatingAccessWidget) as? Bool ?? false
        self.webSearchEnabled = UserDefaults.standard.object(forKey: Keys.webSearchEnabled) as? Bool ?? false

        let themeRaw = UserDefaults.standard.string(forKey: Keys.appTheme) ?? AppTheme.dark.rawValue
        self.appTheme = AppTheme(rawValue: themeRaw) ?? .dark
    }
}
