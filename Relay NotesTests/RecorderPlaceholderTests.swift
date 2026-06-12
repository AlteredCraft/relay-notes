import Testing
@testable import Relay_Notes

/// T1.2f — the recorder placeholder UX shown while a non-streaming engine
/// (Whisper) records. The card itself is SwiftUI (XCUI territory, still
/// unplanned), but its two pure inputs — the elapsed-time label and the
/// normalized audio-meter level — are factored into `nonisolated static`
/// helpers so they can be pinned here. Plus the session-authority signal that
/// decides live-card vs placeholder.
struct RecorderPlaceholderTests {

    // MARK: - Elapsed formatting

    @Test func formatsElapsedAsMinutesSeconds() {
        #expect(RecorderViewModel.formatElapsed(.zero) == "0:00")
        #expect(RecorderViewModel.formatElapsed(.seconds(5)) == "0:05")
        #expect(RecorderViewModel.formatElapsed(.seconds(65)) == "1:05")
        #expect(RecorderViewModel.formatElapsed(.seconds(600)) == "10:00")
        #expect(RecorderViewModel.formatElapsed(.seconds(3_599)) == "59:59")
    }

    @Test func formatElapsedDropsSubSecondRemainder() {
        #expect(RecorderViewModel.formatElapsed(.milliseconds(1_900)) == "0:01")
    }

    @Test func formatElapsedClampsNegativeToZero() {
        // A clock-delta ticker should never feed a negative duration, but the
        // label must degrade gracefully if it ever does.
        #expect(RecorderViewModel.formatElapsed(.seconds(-5)) == "0:00")
    }

    // MARK: - Audio-meter level mapping

    @Test func normalizedLevelFloorsSilence() {
        #expect(RecorderViewModel.normalizedLevel(rms: 0) == 0)
        #expect(RecorderViewModel.normalizedLevel(rms: 0.0001) == 0)  // below the −50 dB floor
    }

    @Test func normalizedLevelCapsAtFullScale() {
        #expect(RecorderViewModel.normalizedLevel(rms: 1) == 1)
        #expect(RecorderViewModel.normalizedLevel(rms: 2) == 1)  // clamp, never overshoot
    }

    @Test func normalizedLevelIsMonotonicInRange() {
        let quiet = RecorderViewModel.normalizedLevel(rms: 0.01)
        let mid = RecorderViewModel.normalizedLevel(rms: 0.1)
        let loud = RecorderViewModel.normalizedLevel(rms: 0.5)
        #expect(quiet < mid)
        #expect(mid < loud)
        #expect((0...1).contains(quiet))
        #expect((0...1).contains(loud))
    }

    // MARK: - Live-partial authority (decides placeholder vs live card)

    @Test func whisperSessionEmitsNoLivePartials() {
        // Whisper accumulates and decodes once at finish — zero partials — so
        // the recorder shows the placeholder instead of a perpetually blank
        // live transcript card.
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        #expect(session.emitsLivePartials == false)
    }
}
