import AppKit
import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class MacSpeechCapture {
    enum State: String { case idle, requestingPermission, recording, transcribing, review }
    private(set) var state: State = .idle
    var transcript = ""
    var errorMessage: String?
    var inputDevices: [MacAudioInput] = []
    var preferredInputUID: String? = UserDefaults.standard.string(forKey: "LemonBot.microphoneUID") {
        didSet {
            if let preferredInputUID { UserDefaults.standard.set(preferredInputUID, forKey: "LemonBot.microphoneUID") }
            else { UserDefaults.standard.removeObject(forKey: "LemonBot.microphoneUID") }
        }
    }
    private(set) var recordingURL: URL?
    private(set) var needsBackendTranscription = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var durationLimit: Task<Void, Never>?
    private var generation = UUID()
    private var holding = false
    private var cues = true

    func refreshInputDevices() {
        do { inputDevices = try MacAudioInputs.available() }
        catch { errorMessage = error.localizedDescription }
    }

    func prepare(cues: Bool) -> UUID? {
        guard state == .idle else { return nil }
        generation = UUID()
        holding = true
        self.cues = cues
        state = .requestingPermission
        errorMessage = nil
        transcript = ""
        return generation
    }

    func begin(language: String?, ticket: UUID) async {
        guard state == .requestingPermission, holding, ticket == generation else { return }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == ticket, holding else { return }
        guard microphone else {
            errorMessage = "Microphone permission denied. Enable Lemon Bot in System Settings → Privacy & Security → Microphone."
            state = .idle
            return
        }
        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == ticket, holding else { return }
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try MacAudioInputs.select(preferredInputUID, on: input.audioUnit)
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw CaptureError.message("No microphone input is available. Select an input device in System Settings → Sound.")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("lemonbot-\(ticket.uuidString).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingURL = url
            let recognizer = language.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()
            var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
            if speechPermission == .authorized, let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                recognitionRequest = request
                self.request = request
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.generation == ticket else { return }
                        if let result { self.transcript = result.bestTranscription.formattedString }
                        if let error {
                            self.errorMessage = error.localizedDescription
                            self.needsBackendTranscription = true
                        }
                        if result?.isFinal == true, self.state == .transcribing { self.finishReview() }
                    }
                }
                needsBackendTranscription = false
            } else {
                needsBackendTranscription = true
                errorMessage = speechPermission != .authorized
                    ? "Apple Speech permission is not granted. After release, explicitly transcribe the recorded audio using the configured backend, or enable Speech Recognition in System Settings."
                    : "On-device Apple Speech is unavailable for this language. After release, explicitly transcribe the recorded audio using the configured backend."
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                recognitionRequest?.append(buffer)
                do { try file.write(from: buffer) }
                catch {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == ticket else { return }
                        self.errorMessage = error.localizedDescription
                        self.cancel()
                    }
                }
            }
            self.engine = engine
            engine.prepare()
            try engine.start()
            state = .recording
            if cues { NSSound(named: "Tink")?.play() }
            durationLimit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                self?.release()
            }
        } catch {
            errorMessage = error.localizedDescription
            cancel()
        }
    }

    func release() {
        holding = false
        if state == .requestingPermission { generation = UUID(); state = .idle; return }
        guard state == .recording else { return }
        stopMicrophone()
        if needsBackendTranscription { state = .review; return }
        state = .transcribing
        request?.endAudio()
        durationLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.finishReview()
        }
    }

    func acceptBackendTranscript(_ text: String) {
        transcript = text
        needsBackendTranscription = false
        errorMessage = nil
        state = .review
    }

    private func finishReview() {
        guard state == .transcribing else { return }
        state = .review
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopMicrophone() {
        durationLimit?.cancel()
        durationLimit = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            if cues { NSSound(named: "Pop")?.play() }
        }
    }

    func cancel() {
        generation = UUID()
        holding = false
        stopMicrophone()
        task?.cancel()
        task = nil
        request = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        transcript = ""
        needsBackendTranscription = false
        state = .idle
    }
}

private enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
