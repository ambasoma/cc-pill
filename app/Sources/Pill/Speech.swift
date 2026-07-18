import AVFoundation
import Foundation
import MBShim
import Speech

/// Voice capture with live partial results; falls back cleanly when the mic
/// or the speech permission is missing (the card shows a text field instead).
@MainActor
final class SpeechInput: ObservableObject {
    enum Phase: Equatable {
        case idle, requesting, recording, denied, unavailable
    }

    @Published var phase: Phase = .idle
    @Published var transcript = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard phase != .recording else { return }
        // No microphone (a Mac mini, typically): never show permission
        // dialogs for hardware that does not exist, just go to type mode.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            phase = .unavailable
            MBLog.log("no mic present: type mode, no permission prompts")
            return
        }
        phase = .requesting
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self else { return }
                guard auth == .authorized else {
                    self.phase = .denied
                    MBLog.log("speech auth denied (\(auth.rawValue))")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        if ok { self.begin() } else {
                            self.phase = .denied
                            MBLog.log("mic access denied")
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            phase = .unavailable
            MBLog.log("speech recognizer unavailable")
            return
        }
        // A Mac mini often has NO microphone at all. Three layers of guard,
        // because installTap raises an ObjC exception (uncatchable in Swift)
        // when the input device is missing or its format is bogus.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            phase = .unavailable
            MBLog.log("no audio input device")
            return
        }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)   // the HARDWARE format
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            phase = .unavailable
            MBLog.log("mic input format invalid (\(fmt.channelCount)ch @ \(fmt.sampleRate)Hz)")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        var reason: NSString?
        let ok = MBTryCatch({
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
        }, &reason)
        guard ok else {
            phase = .unavailable
            MBLog.log("audio tap failed: \(reason ?? "?")")
            return
        }
        do {
            try engine.start()
        } catch {
            phase = .unavailable
            MBLog.log("audio engine failed: \(error.localizedDescription)")
            return
        }
        transcript = ""
        phase = .recording
        MBLog.log("recording started")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let r = result {
                    self.transcript = r.bestTranscription.formattedString
                }
                if error != nil, self.phase == .recording {
                    // Recognition ended (silence timeout etc.); keep the text.
                    self.teardownEngine()
                    self.phase = .idle
                }
            }
        }
    }

    func stop() {
        teardownEngine()
        if phase == .recording || phase == .requesting { phase = .idle }
        MBLog.log("recording stopped, transcript: \(transcript.prefix(60))")
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
