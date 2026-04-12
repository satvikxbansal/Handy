import Foundation
import Speech
import AVFoundation

enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioEngineError(Error)
    case recognitionFailed(Error)
    case noAudioInput
    case siriDisabled

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition not authorized. Please allow in System Settings."
        case .recognizerUnavailable: return "Speech recognizer is not available for your locale."
        case .audioEngineError(let err): return "Audio engine error: \(err.localizedDescription)"
        case .recognitionFailed(let err): return "Recognition failed: \(err.localizedDescription)"
        case .noAudioInput: return "No microphone input available. Check System Settings > Privacy > Microphone."
        case .siriDisabled: return "Siri & Dictation must be enabled. Go to System Settings > Siri (enable Siri) and System Settings > Keyboard > Dictation (enable Dictation), then try again."
        }
    }
}

final class SpeechRecognitionService: NSObject, ObservableObject {
    static let shared = SpeechRecognitionService()

    @Published var isListening = false
    @Published var transcript = ""
    @Published var error: SpeechRecognitionError?

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var onTranscriptCallback: ((String, Bool) -> Void)?

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
        self.onTranscriptCallback = onTranscript

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        // Don't require on-device — it fails if the model isn't downloaded.
        // Apple will prefer on-device automatically when available.
        request.requiresOnDeviceRecognition = false

        request.contextualStrings = [
            "API", "Claude", "OpenAI", "screenshot",
            "navigate", "click", "button", "menu",
            "tab", "window", "browser", "terminal"
        ]

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.channelCount > 0 && hwFormat.sampleRate > 0 else {
            throw SpeechRecognitionError.noAudioInput
        }

        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechRecognitionError.audioEngineError(error)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = text
                    self.onTranscriptCallback?(text, result.isFinal)
                }
            }

            if let error {
                let nsError = error as NSError

                // kAFAssistantErrorDomain codes that are normal/transient:
                //   1    = recognition finished/cancelled
                //   216  = request was cancelled
                //   1101 = assets not installed yet (transient on first use)
                //   1107 = request timed out (will restart)
                //   1110 = no speech detected yet (fires early, not fatal)
                let ignoredCodes: Set<Int> = [1, 216, 1101, 1107, 1110]
                let isIgnorable = nsError.domain == "kAFAssistantErrorDomain"
                    && ignoredCodes.contains(nsError.code)

                if isIgnorable {
                    print("ℹ️ SpeechRecognition (non-fatal, code \(nsError.code)): \(nsError.localizedDescription)")
                    return
                }

                let isSiriDisabled = nsError.domain == "kLSRErrorDomain" && nsError.code == 201
                    || nsError.localizedDescription.lowercased().contains("siri and dictation are disabled")

                DispatchQueue.main.async {
                    self.error = isSiriDisabled ? .siriDisabled : .recognitionFailed(error)
                }
                print("⚠️ SpeechRecognition error: \(error)")
            }
        }

        DispatchQueue.main.async {
            self.isListening = true
            self.transcript = ""
            self.error = nil
        }
    }

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.finish()
        recognitionTask = nil
        onTranscriptCallback = nil

        DispatchQueue.main.async {
            self.isListening = false
        }
    }
}
