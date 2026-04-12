import Foundation
import Speech
import AVFoundation

enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioEngineError(Error)
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized. Please allow in System Settings."
        case .recognizerUnavailable: return "Speech recognizer is not available for your locale."
        case .audioEngineError(let err): return "Audio engine error: \(err.localizedDescription)"
        case .recognitionFailed(let err): return "Recognition failed: \(err.localizedDescription)"
        }
    }
}

/// Apple Speech Recognition service — default STT provider.
/// Uses on-device recognition when available for lower latency.
///
/// Accuracy notes (from Apple docs):
/// - SFSpeechRecognizer supports 50+ locales
/// - On-device mode (requiresOnDeviceRecognition) available on Apple Silicon
/// - Server-based gives better accuracy for complex speech but requires network
/// - taskHint = .dictation optimizes for free-form speech
/// - contextualStrings can boost recognition of domain-specific terms
final class SpeechRecognitionService: NSObject, ObservableObject {
    static let shared = SpeechRecognitionService()

    @Published var isListening = false
    @Published var transcript = ""
    @Published var error: SpeechRecognitionError?

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private override init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func startListening(onTranscript: @escaping (String, Bool) -> Void) throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        request.taskHint = .dictation

        request.contextualStrings = [
            "API", "Claude", "OpenAI", "screenshot",
            "navigate", "click", "button", "menu",
            "tab", "window", "browser", "terminal"
        ]

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            throw SpeechRecognitionError.audioEngineError(error)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = text
                    onTranscript(text, result.isFinal)
                }
            }

            if let error {
                DispatchQueue.main.async {
                    self.error = .recognitionFailed(error)
                    self.stopListening()
                }
            }
        }

        DispatchQueue.main.async {
            self.isListening = true
            self.transcript = ""
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        DispatchQueue.main.async {
            self.isListening = false
        }
    }
}
