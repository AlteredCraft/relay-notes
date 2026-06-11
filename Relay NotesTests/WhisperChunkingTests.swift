import Foundation
import Testing
@testable import Relay_Notes

/// Tests for T1.2d-1's chunked-transcription machinery. Everything here is
/// pure Swift (no MLX), so the whole suite runs on the simulator:
///   - `ChunkedTranscription.run` — the model-agnostic window-walking driver
///   - `WhisperDecoding.parseWindow` — timestamp-token → seek-advance parsing
///   - `WhisperDecoding.timestampRuleMaskRanges` — the structural half of
///     OpenAI's `ApplyTimestampRules` (the probability half needs MLX and is
///     exercised on device via `MLXSmoke`)
struct WhisperChunkingTests {

    // MARK: - Fixtures

    private let window = AudioWindow(sampleRate: 16_000, samplesPerWindow: 480_000)
    private let tsBase = WhisperTokenizer.timestampBase
    private let nVocab = 51_864

    /// A timestamp token id for `seconds` (0.02 s per step).
    private func ts(_ seconds: Double) -> Int {
        tsBase + Int((seconds / 0.02).rounded())
    }

    // MARK: - ChunkedTranscription driver

    @Test
    func shortClipIsSingleWindow() throws {
        let pcm = [Float](repeating: 0, count: 100_000)  // ~6 s, < one window
        var sliceRanges: [Range<Int>] = []
        let text = ChunkedTranscription.run(pcm: pcm, window: window) { slice in
            sliceRanges.append(slice.startIndex..<slice.endIndex)
            return WindowDecodeResult(text: " hello", advance: .fullWindow)
        }
        #expect(text == "hello")
        #expect(sliceRanges == [0..<100_000])
    }

    @Test
    func toTimeAdvanceRestartsMidWindow() throws {
        // 2.5 windows of audio; the first window reports its last complete
        // segment ended at 15 s, so window 2 must start at sample 240_000.
        let pcm = [Float](repeating: 0, count: 1_200_000)
        var sliceStarts: [Int] = []
        var calls = 0
        _ = ChunkedTranscription.run(pcm: pcm, window: window) { slice in
            sliceStarts.append(slice.startIndex)
            calls += 1
            return WindowDecodeResult(
                text: "x",
                advance: calls == 1 ? .toTime(15.0) : .fullWindow
            )
        }
        #expect(sliceStarts == [0, 240_000, 720_000])
    }

    @Test
    func nonPositiveToTimeFallsBackToFullWindow() throws {
        // A zero/negative boundary must not stall the loop.
        let pcm = [Float](repeating: 0, count: 1_200_000)
        var calls = 0
        _ = ChunkedTranscription.run(pcm: pcm, window: window) { _ in
            calls += 1
            return WindowDecodeResult(text: "x", advance: .toTime(0))
        }
        #expect(calls == 3)  // seeks 0, 480k, 960k — terminates
    }

    @Test
    func emptyWindowTextIsSkippedInJoin() throws {
        // Middle window is silence (no-speech skip returns "").
        let pcm = [Float](repeating: 0, count: 1_200_000)
        var calls = 0
        let text = ChunkedTranscription.run(pcm: pcm, window: window) { _ in
            calls += 1
            return WindowDecodeResult(text: calls == 2 ? "" : " part\(calls) ", advance: .fullWindow)
        }
        #expect(text == "part1 part3")
    }

    @Test
    func emptyPCMProducesEmptyTranscript() throws {
        let text = ChunkedTranscription.run(pcm: [], window: window) { _ in
            Issue.record("decodeWindow must not be called for empty PCM")
            return WindowDecodeResult(text: "x", advance: .fullWindow)
        }
        #expect(text == "")
    }

    // MARK: - parseWindow

    @Test
    func noTimestampsKeepsAllTokensAndAdvancesFullWindow() {
        let tokens = [100, 200, 300]
        let parsed = WhisperDecoding.parseWindow(tokens)
        #expect(parsed.contentTokens == tokens)
        #expect(parsed.advance == .fullWindow)
    }

    @Test
    func consecutivePairsDropUnfinishedTailAndSeekToLastBoundary() {
        // <|0.00|> text <|2.00|> <|2.00|> text <|5.00|> <|5.00|> text…(unfinished)
        let tokens = [ts(0), 100, ts(2), ts(2), 200, ts(5), ts(5), 300]
        let parsed = WhisperDecoding.parseWindow(tokens)
        #expect(parsed.contentTokens == [ts(0), 100, ts(2), ts(2), 200, ts(5)])
        #expect(parsed.advance == .toTime(5.0))
    }

    @Test
    func singleTimestampEndingWithPairsConsumesEverything() {
        // …<|2.00|> <|2.00|> text <|5.00|> — trailing single timestamp means
        // silence after it; whole window is consumed.
        let tokens = [ts(0), 100, ts(2), ts(2), 200, ts(5)]
        let parsed = WhisperDecoding.parseWindow(tokens)
        #expect(parsed.contentTokens == tokens)
        #expect(parsed.advance == .fullWindow)
    }

    @Test
    func singleSegmentWithoutPairsAdvancesFullWindow() {
        // <|0.00|> text <|5.50|> — no consecutive pair at all.
        let tokens = [ts(0), 100, 200, ts(5.5)]
        let parsed = WhisperDecoding.parseWindow(tokens)
        #expect(parsed.contentTokens == tokens)
        #expect(parsed.advance == .fullWindow)
    }

    // MARK: - timestampRuleMaskRanges (structural half of ApplyTimestampRules)

    @Test
    func initialStepForcesTimestampAndCapsInitialValue() {
        let ranges = WhisperDecoding.timestampRuleMaskRanges(sampled: [], nVocab: nVocab)
        // Force a timestamp first: all text masked.
        #expect(ranges.contains(0..<tsBase))
        // max_initial_timestamp = 1.0 s → ids above tsBase+50 masked.
        #expect(ranges.contains((tsBase + 51)..<nVocab))
        // <|notimestamps|> always masked in timestamp mode.
        #expect(ranges.contains(WhisperTokenizer.notimestamps..<(WhisperTokenizer.notimestamps + 1)))
    }

    @Test
    func afterInitialTimestampAllTimestampsMasked() {
        // seq = [<|1.00|>]: last is ts, "penultimate" defaults true for len<2
        // → next token must be text.
        let ranges = WhisperDecoding.timestampRuleMaskRanges(sampled: [ts(1)], nVocab: nVocab)
        #expect(ranges.contains(tsBase..<nVocab))
    }

    @Test
    func afterTextTimestampsMustNotDecrease() {
        // seq = [<|1.00|>, text]: next timestamp must be strictly greater
        // than <|1.00|> (monotonicity, OpenAI semantics — the mlx-examples
        // port has an index/value bug that no-ops this rule).
        let ranges = WhisperDecoding.timestampRuleMaskRanges(sampled: [ts(1), 100], nVocab: nVocab)
        #expect(ranges.contains(tsBase..<(ts(1) + 1)))
        #expect(!ranges.contains(0..<WhisperTokenizer.eot))
    }

    @Test
    func segmentClosingTimestampForcesTimestampOrEOT() {
        // seq = [<|1.00|>, text, <|3.00|>]: last is ts after text → next must
        // be a timestamp (pair) or EOT; text is masked. Repeating <|3.00|>
        // stays legal (that's the pair), so the monotonic mask stops below it.
        let ranges = WhisperDecoding.timestampRuleMaskRanges(sampled: [ts(1), 100, ts(3)], nVocab: nVocab)
        #expect(ranges.contains(0..<WhisperTokenizer.eot))
        #expect(ranges.contains(tsBase..<ts(3)))
        #expect(!ranges.contains(tsBase..<(ts(3) + 1)))
    }

    // MARK: - Tokenizer timestamp helpers

    @Test
    func timestampSecondsConversion() {
        #expect(WhisperTokenizer.timestampSeconds(tsBase) == 0.0)
        #expect(WhisperTokenizer.timestampSeconds(tsBase + 50) == 1.0)
        #expect(WhisperTokenizer.timestampSeconds(WhisperTokenizer.notimestamps) == nil)
    }
}
