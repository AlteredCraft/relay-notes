import Foundation
import Testing

@testable import Relay_Notes

/// Coverage for the long-audio chunk merge (`ParakeetChunkMerge`, T2.1e) — pure
/// integer-id + Double-timestamp math, so simulator-safe (no MLX, runs on every
/// `xcodebuild test`). Exercises each branch of the senstella `alignment.py` port:
/// straight concatenation, the thin-overlap cutoff, the contiguous-run dedup, and
/// the LCS fallback. The on-device end-to-end check is `ParakeetSmoke.runChunked`.
struct ParakeetChunkingTests {

    /// 1-second token at `start` with id `id` (text is irrelevant to the merge,
    /// which keys on id + timestamp).
    private static func tok(_ id: Int, _ start: Double, dur: Double = 1) -> ParakeetToken {
        ParakeetToken(id: id, text: "t\(id)", start: start, duration: dur)
    }

    @Test func endIsStartPlusDuration() {
        #expect(Self.tok(1, 2.5, dur: 0.5).end == 3.0)
    }

    @Test func emptyInputsReturnTheOther() {
        let b = [Self.tok(1, 0)]
        #expect(ParakeetChunkMerge.merge([], b, overlapDuration: 4).map(\.id) == [1])
        #expect(ParakeetChunkMerge.merge(b, [], overlapDuration: 4).map(\.id) == [1])
    }

    /// `a` ends before `b` begins → no overlap → plain concatenation (nothing dropped).
    @Test func noTemporalOverlapConcatenates() {
        let a = [Self.tok(1, 0)]            // end 1
        let b = [Self.tok(2, 2)]            // start 2
        #expect(ParakeetChunkMerge.merge(a, b, overlapDuration: 4).map(\.id) == [1, 2])
    }

    /// Overlap too thin to align (only one token in `a`'s overlap window) → midpoint
    /// cutoff: keep `a` before the midpoint, `b` after — the shared pair is dropped.
    @Test func thinOverlapFallsBackToCutoff() {
        let a = [Self.tok(1, 0), Self.tok(2, 5)]      // ends 1, 6
        let b = [Self.tok(3, 5.5), Self.tok(4, 10)]   // starts 5.5, 10
        // cutoff = (6 + 5.5)/2 = 5.75 → keep a.end<=5.75 ([1]) + b.start>=5.75 ([4]).
        #expect(ParakeetChunkMerge.merge(a, b, overlapDuration: 2).map(\.id) == [1, 4])
    }

    /// A clean contiguous overlap (shared ids 14,15 at matching times) is deduped —
    /// the merged stream carries each shared token exactly once.
    @Test func contiguousOverlapDeduplicates() {
        let a = (0 ..< 6).map { Self.tok(10 + $0, Double($0)) }   // ids 10…15 @ 0…5
        let b = [Self.tok(14, 4), Self.tok(15, 5), Self.tok(16, 6), Self.tok(17, 7)]
        let merged = ParakeetChunkMerge.merge(a, b, overlapDuration: 2)
        #expect(merged.map(\.id) == [10, 11, 12, 13, 14, 15, 16, 17])
    }

    /// When the matched tokens aren't contiguous (an `a`-only `99` splits the run),
    /// `longestContiguous` bails (nil) and `merge` uses the LCS fallback, which
    /// keeps the gap token and appends `b`'s tail without duplicating 14/15.
    @Test func nonContiguousFallsBackToLCS() {
        let a = [Self.tok(10, 0), Self.tok(11, 1), Self.tok(14, 2), Self.tok(99, 3), Self.tok(15, 4)]
        let b = [Self.tok(14, 2), Self.tok(15, 4), Self.tok(16, 5)]

        // The contiguous merge gives up (longest run = 1 < enoughPairs = 2).
        #expect(ParakeetChunkMerge.longestContiguous(a, b, overlapDuration: 4) == nil)
        // The fallback stitches: a-gap `99` preserved, b-tail `16` appended, no dup.
        #expect(ParakeetChunkMerge.merge(a, b, overlapDuration: 4).map(\.id) == [10, 11, 14, 99, 15, 16])
    }
}
