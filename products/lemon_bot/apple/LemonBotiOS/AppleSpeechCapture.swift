import AVFoundation
import Speech
import Observation
import AudioToolbox

@MainActor @Observable
final class AppleSpeechCapture {
    var text = ""
    var recording = false
    var preparing = false
    var error: String?
    var processing = ""
    var cuesEnabled = true
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false
    private var generation = UUID()
    private var stopTimer: Task<Void, Never>?

    func start(language: String?) async {
        guard !recording, !preparing else { return }
        preparing = true
        error = nil
        text = ""
        let current = UUID()
        generation = current
        defer { preparing = false }
        do {
            let speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard speechAllowed else { throw CaptureError.message("Apple Speech permission is denied or restricted. Enable Speech Recognition for Lemon Bot in iOS Settings.") }
            let micAllowed = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard micAllowed else { throw CaptureError.message("Microphone permission is denied. Enable Microphone for Lemon Bot in iOS Settings.") }
            guard generation == current else { return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language ?? Locale.current.identifier)), recognizer.isAvailable else {
                throw CaptureError.message("Apple Speech recognition is unavailable for this language or device. Check connectivity and the selected language.")
            }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            processing = recognizer.supportsOnDeviceRecognition ? "On-device Apple Speech" : "Apple Speech network processing"
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.message("No microphone input is available. Check the connected audio device.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failureText = failure?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    if let text { self.text = text }
                    if let failureText { self.error = failureText }
                    if final || failureText != nil { self.finishCapture() }
                }
            }
            engine.prepare()
            try engine.start()
            recording = true
            if cuesEnabled { AudioServicesPlaySystemSound(1113) }
            stopTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            self.error = error.localizedDescription
            finishCapture()
        }
    }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        if engine.isRunning { engine.stop() }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio()
        // Stop is the review boundary: late recognition must not overwrite user edits.
        generation = UUID()
        task?.cancel()
        task = nil
        request = nil
        if recording, cuesEnabled { AudioServicesPlaySystemSound(1114) }
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishCapture() { stop() }

    func cancel(clearText: Bool = true) {
        stop()
        if clearText { text = "" }
    }
}
