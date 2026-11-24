import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class MeetingAudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    /// When `currentTime` was last read back from the player. The UI adds the
    /// time elapsed since this moment to draw a smooth position between polls.
    private var confirmedAt: Date?

    // MARK: - Playback

    func load(url: URL) {
        stop()

        // A meeting recorded in this session has no audio file until the
        // recording is saved, so stay silent instead of surfacing an error.
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = nil
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            confirmedAt = nil
            errorMessage = nil
        } catch {
            player = nil
            duration = 0
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        guard let player else {
            return
        }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            // Freeze the reported position at the exact pause point and stop
            // polling, so a later wake-up cannot mistake the pause for the end
            // of playback and jump the progress bar to the end.
            currentTime = player.currentTime
            confirmedAt = nil
            progressTask?.cancel()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            #endif
        } else {
            if player.currentTime >= max(player.duration - 0.1, 0) {
                player.currentTime = 0
            }

            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            player.play()
            isPlaying = true
            currentTime = player.currentTime
            confirmedAt = .now
            startProgressUpdates()
        }
    }

    func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    func seek(to time: TimeInterval) {
        guard let player else {
            return
        }

        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
        confirmedAt = .now
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        confirmedAt = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    // MARK: - Progress updates

    /// Playback position interpolated to `date` so the progress UI can advance
    /// every frame instead of stepping once per poll. While paused it returns
    /// the frozen position.
    func playbackTime(at date: Date) -> TimeInterval {
        guard isPlaying, let confirmedAt else {
            return currentTime
        }

        return min(currentTime + date.timeIntervalSince(confirmedAt), duration)
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))

                guard let self, let player = self.player, self.isPlaying else {
                    return
                }

                // `AVAudioPlayer.isPlaying` is false both when paused and when
                // the file ends. The pause path clears `isPlaying` before
                // cancelling this task, so a stopped player here always means
                // playback reached the end of the file; a poll that slips
                // through a pause is caught by the guard instead and leaves
                // the frozen position alone, keeping the progress bar from
                // jumping to the end.
                if !player.isPlaying {
                    self.isPlaying = false
                    self.currentTime = player.duration
                    self.confirmedAt = nil
                    return
                }

                self.currentTime = player.currentTime
                self.confirmedAt = .now
            }
        }
    }
}
