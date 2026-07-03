import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechService: NSObject {
    nonisolated static let unavailableMessage = "Speech recognition is not available in this environment."

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String) -> Void)?
    private var stateHandler: ((Bool) -> Void)?
    private(set) var isListening = false
    private var lastSpokenMessageId: String?

    func startRecognition(
        onTranscript: @escaping (String) -> Void,
        onStateChange: @escaping (Bool) -> Void
    ) async throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechServiceError.unavailable
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw SpeechServiceError.unavailable }

        transcriptHandler = onTranscript
        stateHandler = onStateChange
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            throw error
        }

        isListening = true
        onStateChange(true)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty { self.transcriptHandler?(transcript) }
                    self.stopRecognition()
                } else if error != nil {
                    self.stopRecognition()
                }
            }
        }
    }

    func stopRecognition() {
        guard isListening || recognitionTask != nil || request != nil else { return }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if isListening {
            isListening = false
            stateHandler?(false)
        }
    }

    func speak(message: AiMessage) {
        guard message.role == .assistant, message.id != lastSpokenMessageId else { return }
        lastSpokenMessageId = message.id
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message.content)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        synthesizer.speak(utterance)
    }

    func cancelSpeech() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private enum SpeechServiceError: LocalizedError {
    case unavailable
    var errorDescription: String? { SpeechService.unavailableMessage }
}
