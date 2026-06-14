import Foundation
import Testing

@testable import Relay_Notes

/// Pure vocab-decode coverage for `parakeetDecodeTokens` — simulator-safe (no
/// MLX). Pins the `▁`→space substitution, joining, and the out-of-range guard
/// (the TDT decode never emits the blank index, but a defensive decode shouldn't
/// trap on an id past the vocabulary).
struct ParakeetTokenizerTests {
    private static let vocab = ["<unk>", "\u{2581}openly", "\u{2581}shouldered", "ly"]

    @Test func mapsUnderscoreToSpaceAndJoins() {
        // ▁openly + ▁shouldered → " openly shouldered"; "ly" appends with no space.
        let text = parakeetDecodeTokens([1, 2, 3], vocabulary: Self.vocab)
        #expect(text == " openly shouldered" + "ly")
    }

    @Test func skipsOutOfRangeIds() {
        // blankIndex (== vocab.count) and any id past the table are dropped, not trapped.
        #expect(parakeetDecodeTokens([1, 99, 2], vocabulary: Self.vocab) == " openly shouldered")
        #expect(parakeetDecodeTokens([Self.vocab.count], vocabulary: Self.vocab) == "")
        #expect(parakeetDecodeTokens([-1], vocabulary: Self.vocab) == "")
    }

    @Test func emptyInputIsEmptyString() {
        #expect(parakeetDecodeTokens([], vocabulary: Self.vocab) == "")
    }
}
