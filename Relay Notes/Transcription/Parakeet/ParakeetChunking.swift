import Foundation

/// Long-audio chunking support for Parakeet TDT (T2.1e). A `ParakeetToken` is one
/// decoded vocab token with its **time alignment** (seconds); `ParakeetChunkMerge`
/// stitches the per-chunk token streams across overlapping window boundaries.
///
/// Parakeet has no Whisper-style timestamp tokens, so long audio is handled by
/// the senstella reference's own scheme: step the audio in `chunkDuration`
/// windows with `overlapDuration` overlap, decode each independently, offset each
/// chunk's token timestamps by the chunk start, and **merge the overlap** so the
/// shared region isn't duplicated or dropped (see `ParakeetTDTModel.transcribeChunked`).
///
/// **Pure value types — no MLX** (the merge is integer-id + Double-timestamp math),
/// so this file compiles *and runs* on the simulator and is unit-tested directly
/// (`ParakeetChunkingTests`), unlike the MLX-touching decode it feeds.
///
/// Ports `senstella/parakeet-mlx`'s `alignment.py` (`AlignedToken`,
/// `merge_longest_contiguous`, `merge_longest_common_subsequence`) verbatim — the
/// FluidInference Swift port ships only a simplified cutoff stub
/// (`mergeLongestContiguous`) that drops/duplicates words at boundaries; we port
/// the real algorithm (plan.T2.md §5.5).
///
/// `nonisolated` — isolation-neutral, like the other Parakeet helpers.

// MARK: - Time-aligned token

nonisolated struct ParakeetToken: Sendable, Equatable {
    let id: Int
    /// Decoded piece text (`▁` already mapped to space), so `tokens.map(\.text).joined()`
    /// reproduces `parakeetDecodeTokens(ids:)` exactly when no merge occurs.
    let text: String
    /// Emission time in seconds (`step · timeRatio`). Mutated by the chunk loop to
    /// add the chunk offset; the merge keys off it for the proximity guard.
    var start: Double
    /// Frame-duration in seconds (`durations[decision] · timeRatio`).
    var duration: Double

    var end: Double { start + duration }
}

// MARK: - Overlap merge

nonisolated enum ParakeetChunkMerge {

    /// The driver's merge: try the contiguous-run merge, and on failure (no run of
    /// at least half the overlap tokens — the Python `RuntimeError`) fall back to the
    /// longest-common-subsequence merge. Mirrors `transcribe`'s try/except in `parakeet.py`.
    static func merge(
        _ a: [ParakeetToken], _ b: [ParakeetToken], overlapDuration: Double
    ) -> [ParakeetToken] {
        longestContiguous(a, b, overlapDuration: overlapDuration)
            ?? longestCommonSubsequence(a, b, overlapDuration: overlapDuration)
    }

    /// Port of `merge_longest_contiguous`. Returns `nil` only where the Python
    /// raises `RuntimeError` (longest contiguous matched run shorter than half the
    /// overlap) — the signal to fall back to LCS. All other cases return a value:
    /// straight concatenation when the chunks don't overlap in time, or a midpoint
    /// cutoff when there's too little overlap to align.
    static func longestContiguous(
        _ a: [ParakeetToken], _ b: [ParakeetToken], overlapDuration: Double
    ) -> [ParakeetToken]? {
        if a.isEmpty || b.isEmpty { return a.isEmpty ? b : a }

        let aEnd = a[a.count - 1].end
        let bStart = b[0].start
        if aEnd <= bStart { return a + b }  // no temporal overlap → just concatenate

        let overlapA = a.filter { $0.end > bStart - overlapDuration }
        let overlapB = b.filter { $0.start < aEnd + overlapDuration }
        let enoughPairs = overlapA.count / 2

        if overlapA.count < 2 || overlapB.count < 2 {
            return cutoff(a, b, aEnd: aEnd, bStart: bStart)
        }

        // Longest run of consecutive (id-equal, time-close) pairs through the overlap.
        var best: [(Int, Int)] = []
        for i in overlapA.indices {
            for j in overlapB.indices where pairMatches(overlapA[i], overlapB[j], overlapDuration: overlapDuration) {
                var current: [(Int, Int)] = []
                var k = i, l = j
                while k < overlapA.count, l < overlapB.count,
                      pairMatches(overlapA[k], overlapB[l], overlapDuration: overlapDuration) {
                    current.append((k, l))
                    k += 1
                    l += 1
                }
                if current.count > best.count { best = current }
            }
        }

        guard best.count >= enoughPairs else { return nil }  // Python: raise → caller uses LCS

        let aStartIdx = a.count - overlapA.count
        return stitch(
            a, b,
            indicesA: best.map { aStartIdx + $0.0 },
            indicesB: best.map { $0.1 })
    }

    /// Port of `merge_longest_common_subsequence` — the fallback. Same no-overlap /
    /// too-little-overlap exits, then a classic LCS DP over the overlap windows
    /// (matching on id + timestamp proximity), backtracked to the matched index pairs.
    static func longestCommonSubsequence(
        _ a: [ParakeetToken], _ b: [ParakeetToken], overlapDuration: Double
    ) -> [ParakeetToken] {
        if a.isEmpty || b.isEmpty { return a.isEmpty ? b : a }

        let aEnd = a[a.count - 1].end
        let bStart = b[0].start
        if aEnd <= bStart { return a + b }

        let overlapA = a.filter { $0.end > bStart - overlapDuration }
        let overlapB = b.filter { $0.start < aEnd + overlapDuration }

        if overlapA.count < 2 || overlapB.count < 2 {
            return cutoff(a, b, aEnd: aEnd, bStart: bStart)
        }

        let m = overlapA.count, n = overlapB.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1 ... m {
            for j in 1 ... n {
                if pairMatches(overlapA[i - 1], overlapB[j - 1], overlapDuration: overlapDuration) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var i = m, j = n
        while i > 0, j > 0 {
            if pairMatches(overlapA[i - 1], overlapB[j - 1], overlapDuration: overlapDuration) {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        pairs.reverse()

        if pairs.isEmpty { return cutoff(a, b, aEnd: aEnd, bStart: bStart) }

        let aStartIdx = a.count - overlapA.count
        return stitch(
            a, b,
            indicesA: pairs.map { aStartIdx + $0.0 },
            indicesB: pairs.map { $0.1 })
    }

    // MARK: - Shared internals

    /// Two tokens align iff same id and starts within half the overlap window.
    private static func pairMatches(
        _ x: ParakeetToken, _ y: ParakeetToken, overlapDuration: Double
    ) -> Bool {
        x.id == y.id && abs(x.start - y.start) < overlapDuration / 2
    }

    /// Midpoint split used when the overlap is too thin to align: keep `a` up to the
    /// time midpoint, then `b` from it. Ports the `cutoff_time` branch shared by both merges.
    private static func cutoff(
        _ a: [ParakeetToken], _ b: [ParakeetToken], aEnd: Double, bStart: Double
    ) -> [ParakeetToken] {
        let cutoffTime = (aEnd + bStart) / 2
        return a.filter { $0.end <= cutoffTime } + b.filter { $0.start >= cutoffTime }
    }

    /// The result-construction shared by both merges once the matched index pairs
    /// (absolute into `a` and `b`) are known: take `a` up to the first match, then
    /// for each matched pair emit `a`'s token and bridge any gap to the next match
    /// with whichever side carried more tokens, finally append `b`'s tail after the
    /// last match. Ports the identical tail of both Python functions.
    private static func stitch(
        _ a: [ParakeetToken], _ b: [ParakeetToken],
        indicesA: [Int], indicesB: [Int]
    ) -> [ParakeetToken] {
        var result: [ParakeetToken] = []
        result.append(contentsOf: a[..<indicesA[0]])

        for k in indicesA.indices {
            let idxA = indicesA[k]
            let idxB = indicesB[k]
            result.append(a[idxA])

            if k < indicesA.count - 1 {
                let nextIdxA = indicesA[k + 1]
                let nextIdxB = indicesB[k + 1]
                let gapA = Array(a[(idxA + 1) ..< nextIdxA])
                let gapB = Array(b[(idxB + 1) ..< nextIdxB])
                result.append(contentsOf: gapB.count > gapA.count ? gapB : gapA)
            }
        }

        result.append(contentsOf: b[(indicesB[indicesB.count - 1] + 1)...])
        return result
    }
}
