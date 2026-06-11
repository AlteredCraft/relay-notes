import Foundation
import Testing
@testable import Relay_Notes

/// All tests here are simulator-safe — the tokenizer is pure Swift bytes work,
/// no MLX involvement.
struct WhisperTokenizerTests {

    @Test
    func tokenizerLoadsFromBundle() throws {
        // Just ensuring init() succeeds with the bundled `gpt2.tiktoken` is the
        // load-bearing assertion — `init` throws `.vocabIncomplete` if any of
        // the 50256 ranks is missing.
        _ = try WhisperTokenizer(location: .bundled)
    }

    @Test
    func specialTokenIDsAtExpectedPositions() {
        // Lifted from the Python research table (planning notes 2026-06-10).
        // These IDs are load-bearing for the greedy decoder's prime sequence
        // and the eot / SuppressTokens logic in T1.1b-4.
        #expect(WhisperTokenizer.eot          == 50_256)
        #expect(WhisperTokenizer.sot          == 50_257)
        #expect(WhisperTokenizer.en           == 50_258)
        #expect(WhisperTokenizer.transcribe   == 50_358)
        #expect(WhisperTokenizer.notimestamps == 50_362)
        #expect(WhisperTokenizer.timestampBase == 50_363)
    }

    @Test
    func sotSequenceIsBareSOTForEnglishOnly() {
        // English-only models have no language/task tokens; timestamp mode
        // (T1.2d-1) means <|notimestamps|> is never primed.
        #expect(WhisperTokenizer.sotSequence == [WhisperTokenizer.sot])
    }

    @Test
    func decodeASCIISingleByteTokens() throws {
        // The first 5 ranks in `gpt2.tiktoken` are the printable ASCII bytes
        // 0x21..0x25 ("!\"#$%") in raw form.
        let tokenizer = try WhisperTokenizer(location: .bundled)
        #expect(tokenizer.decode([0, 1, 2, 3, 4]) == "!\"#$%")
    }

    @Test
    func decodeSkipsSpecialTokens() throws {
        let tokenizer = try WhisperTokenizer(location: .bundled)
        let ids = [
            WhisperTokenizer.sot,           // skipped
            0,                              // "!"
            WhisperTokenizer.notimestamps,  // skipped
            1,                              // "\""
            WhisperTokenizer.eot,           // skipped
        ]
        #expect(tokenizer.decode(ids) == "!\"")
    }

    @Test
    func decodeEmptyArrayReturnsEmptyString() throws {
        let tokenizer = try WhisperTokenizer(location: .bundled)
        #expect(tokenizer.decode([]) == "")
    }

    @Test
    func decodeIgnoresOutOfRangeIDs() throws {
        let tokenizer = try WhisperTokenizer(location: .bundled)
        // Negative and overflow IDs should be filtered out, valid ones decoded.
        #expect(tokenizer.decode([-1, 999_999, 0]) == "!")
    }
}
