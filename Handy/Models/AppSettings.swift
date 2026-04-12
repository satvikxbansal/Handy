import Foundation

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
    case elevenLabs = "ElevenLabs"
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

    private enum Keys {
        static let assistantMode = "handy_assistantMode"
        static let sttProvider = "handy_sttProvider"
        static let ttsProvider = "handy_ttsProvider"
    }

    private init() {
        let modeRaw = UserDefaults.standard.string(forKey: Keys.assistantMode) ?? AssistantMode.helpOnly.rawValue
        self.assistantMode = AssistantMode(rawValue: modeRaw) ?? .helpOnly

        let sttRaw = UserDefaults.standard.string(forKey: Keys.sttProvider) ?? STTProvider.apple.rawValue
        self.sttProvider = STTProvider(rawValue: sttRaw) ?? .apple

        let ttsRaw = UserDefaults.standard.string(forKey: Keys.ttsProvider) ?? TTSProvider.system.rawValue
        self.ttsProvider = TTSProvider(rawValue: ttsRaw) ?? .system
    }
}
