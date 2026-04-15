import Foundation
import AVFoundation
import AppKit

/// Text-to-Speech service with pluggable providers.
/// Default: macOS `AVSpeechSynthesizer`.
/// Optional: [Sarvam Bulbul v3](https://docs.sarvam.ai/api-reference-docs/getting-started/models/bulbul) via API key; falls back to system speech on any failure.
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if AppSettings.shared.ttsProvider == .sarvam,
           KeychainManager.getAPIKey(.sarvam) != nil {
            speakWithSarvam(trimmed)
        } else {
            speakWithSystem(trimmed)
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

    /// POST `https://api.sarvam.ai/text-to-speech` — response `audios` are base64 WAV per [Sarvam REST docs](https://docs.sarvam.ai/api-reference-docs/text-to-speech/convert).
    private func speakWithSarvam(_ text: String) {
        guard let apiKey = KeychainManager.getAPIKey(.sarvam), !apiKey.isEmpty else {
            speakWithSystem(text)
            return
        }

        let speaker = AppSettings.shared.sarvamVoice.rawValue
        guard let url = URL(string: "https://api.sarvam.ai/text-to-speech") else {
            speakWithSystem(text)
            return
        }

        DispatchQueue.main.async { self.isSpeaking = true }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "target_language_code": "en-IN",
            "model": "bulbul:v3",
            "speaker": speaker
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            func fallback() {
                DispatchQueue.main.async { [weak self] in
                    self?.speakWithSystem(text)
                }
            }

            if error != nil {
                fallback()
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                fallback()
                return
            }

            let decoded: SarvamTTSResponse
            do {
                decoded = try JSONDecoder().decode(SarvamTTSResponse.self, from: data)
            } catch {
                fallback()
                return
            }

            guard let b64 = decoded.audios.first,
                  let wavData = Data(base64Encoded: b64),
                  !wavData.isEmpty else {
                fallback()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do {
                    self.audioPlayer = try AVAudioPlayer(data: wavData)
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.prepareToPlay()
                    self.audioPlayer?.play()
                } catch {
                    self.speakWithSystem(text)
                }
            }
        }.resume()
    }
}

private struct SarvamTTSResponse: Decodable {
    let audios: [String]
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
