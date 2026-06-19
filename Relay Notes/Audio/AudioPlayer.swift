import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var pollingTask: Task<Void, Never>?

    func load(url: URL) {
        stop()
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.currentTime = 0
        } catch {
            self.errorMessage = "Couldn't load the audio for this note."
            self.player = nil
            self.duration = 0
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        if currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else {
            errorMessage = "Couldn't start playback. Please try again."
            return
        }
        isPlaying = true
        startPolling()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopPolling()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopPolling()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startPolling() {
        stopPolling()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying && isPlaying {
            isPlaying = false
            stopPolling()
            // Within this much of the end, snap to the exact duration so the
            // scrubber lands on 0:00-remaining instead of a fraction short.
            let endSnapThreshold: TimeInterval = 0.05
            if currentTime >= duration - endSnapThreshold {
                currentTime = duration
            }
        }
    }
}
