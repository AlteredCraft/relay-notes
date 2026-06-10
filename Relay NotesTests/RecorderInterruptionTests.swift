import Testing
@testable import Relay_Notes

/// Unit tests for the interruption → state mapping that drives `.paused` recovery.
/// These cover the pure, side-effect-free transitions in `RecorderViewModel.nextState`.
@MainActor
struct RecorderInterruptionTests {

    @Test func beganWhileRecordingPausesAndKeepsPartial() {
        let next = RecorderViewModel.nextState(for: .began, from: .recording(partial: "hello"))
        #expect(next == .paused(partial: "hello"))
    }

    @Test func resumedWhilePausedReturnsToRecordingWithSamePartial() {
        let next = RecorderViewModel.nextState(for: .resumed, from: .paused(partial: "hello"))
        #expect(next == .recording(partial: "hello"))
    }

    @Test func beganIsIgnoredWhenNotRecording() {
        #expect(RecorderViewModel.nextState(for: .began, from: .paused(partial: "x")) == nil)
        #expect(RecorderViewModel.nextState(for: .began, from: .finalizing) == nil)
        #expect(RecorderViewModel.nextState(for: .began, from: .idle) == nil)
        #expect(RecorderViewModel.nextState(for: .began, from: .finished(transcript: "x")) == nil)
    }

    @Test func resumedIsIgnoredWhenNotPaused() {
        #expect(RecorderViewModel.nextState(for: .resumed, from: .recording(partial: "x")) == nil)
        #expect(RecorderViewModel.nextState(for: .resumed, from: .idle) == nil)
        #expect(RecorderViewModel.nextState(for: .resumed, from: .finalizing) == nil)
    }

    @Test func stoppedNeverMapsToAPureState() {
        // `.stopped` drives finalize as a side effect; it must not produce a direct state here.
        #expect(RecorderViewModel.nextState(for: .stopped, from: .paused(partial: "x")) == nil)
        #expect(RecorderViewModel.nextState(for: .stopped, from: .recording(partial: "x")) == nil)
    }
}
