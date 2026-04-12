import Foundation
import AVFoundation
import AppKit

/// Text-to-Speech service with pluggable providers.
/// Default: macOS AVSpeechSynthesizer.
/// Optional: ElevenLabs via API key.
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    private let systemSynth = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    private override init() {
        super.init()
        systemSynth.delegate = self
    }

    func speak(_ text: String) {
        if AppSettings.shared.ttsProvider == .elevenLabs,
           let _ = KeychainManager.getAPIKey(.elevenLabs) {
            speakWithElevenLabs(text)
        } else {
            speakWithSystem(text)
        }
    }

    func stop() {
        systemSynth.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    private func speakWithSystem(_ text: String) {
        DispatchQueue.main.async { self.isSpeaking = true }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        systemSynth.speak(utterance)
    }

    private func speakWithElevenLabs(_ text: String) {
        guard let apiKey = KeychainManager.getAPIKey(.elevenLabs) else {
            speakWithSystem(text)
            return
        }

        DispatchQueue.main.async { self.isSpeaking = true }

        let voiceID = "21m00Tcm4TlvDq8ikWAM"
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let data, error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { [weak self] in
                    self?.speakWithSystem(text)
                }
                return
            }

            do {
                self.audioPlayer = try AVAudioPlayer(data: data)
                self.audioPlayer?.delegate = self
                self.audioPlayer?.play()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.speakWithSystem(text)
                }
            }
        }.resume()
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

extension TTSService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}
