import AVFoundation
import Foundation
import Observation

#if os(iOS)
import AVFAudio
#endif

@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var duration: TimeInterval = 0
    private(set) var recordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var timerTask: Task<Void, Never>?

    func start() async throws {
        guard !isRecording else {
            return
        }

        let granted = await requestMicrophoneAccess()
        guard granted else {
            throw RecordingError.permissionDenied
        }

        #if os(iOS)
        try configureAudioSession()
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw RecordingError.cannotStart
        }

        self.recorder = recorder
        recordingURL = url
        duration = 0
        isRecording = true
        startTimer()
    }

    @discardableResult
    func stop() -> URL? {
        guard let recorder else {
            return nil
        }

        duration = recorder.currentTime
        recorder.stop()
        recorder.isMeteringEnabled = false
        self.recorder = nil
        isRecording = false

        timerTask?.cancel()
        timerTask = nil
        duration = max(duration, recorder.currentTime)

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif

        return recordingURL
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        duration = 0

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }

        recordingURL = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))

                guard let self, self.isRecording else {
                    return
                }

                self.duration = self.recorder?.currentTime ?? self.duration
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    #if os(iOS)
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
    }
    #endif
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case permissionDenied
    case cannotStart

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .permissionDenied:
            return language.text("recording.error.permissionDenied")
        case .cannotStart:
            return language.text("recording.error.cannotStart")
        }
    }
}
