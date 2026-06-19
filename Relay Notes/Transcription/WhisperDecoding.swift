import Foundation
import MLX

/// Whisper's greedy decode loop, ported from the subset of
/// `mlx_whisper/decoding.py` needed for English-only, greedy, timestamp-mode
/// inference. Beam search, sampling, language detection, and the temperature
/// retry loop are dropped. Timestamp decoding (`ApplyTimestampRules`) *is*
/// ported (T1.2d-1) because the long-audio seek loop needs segment boundaries.
///
/// One deliberate deviation from `mlx-examples`: its `ApplyTimestampRules`
/// monotonicity rule confuses token indices with token values
/// (`timestamps = [i for i, v in enumerate(seq) …]` then masks
/// `timestamp_begin : timestamps[-1]` — an empty range), silently no-oping
/// the "timestamps shouldn't decrease" constraint. We port the semantics of
/// OpenAI's original `whisper/decoding.py` instead, which masks token
/// *values* below the last emitted timestamp.
nonisolated enum WhisperDecoding {

    // MARK: - Suppress sets

    /// 84 token IDs that the decoder suppresses every step — non-speech symbols
    /// (punctuation past the basics, brackets, musical notes, etc.).
    ///
    /// The set is deterministic per vocab — the Python reference computes it
    /// every time by tokenizing a hardcoded symbol list (`mlx_whisper/tokenizer.py`,
    /// `Tokenizer.non_speech_tokens`). We bake the result in as a literal rather
    /// than porting `tiktoken`'s encoder to Swift just to recompute a constant
    /// at every model load.
    ///
    /// Provenance: generated 2026-06-10 by `scripts/compute-non-speech-tokens.py`
    /// against the bundled `gpt2.tiktoken`. Re-run that script if the vocab ever
    /// changes (it shouldn't — frozen upstream).
    static let nonSpeechTokens: Set<Int> = [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27,
        28, 29, 31, 58, 59, 60, 61, 62, 63, 90,
        91, 92, 93, 357, 366, 438, 532, 685, 705, 796,
        930, 1058, 1220, 1267, 1279, 1303, 1343, 1377, 1391, 1635,
        1782, 1875, 2162, 2361, 2488, 3467, 4008, 4211, 4600, 4808,
        5299, 5855, 6329, 7203, 9609, 9959, 10563, 10786, 11420, 11709,
        11907, 13163, 13697, 13700, 14808, 15306, 16410, 16791, 17992, 19203,
        19510, 20724, 22305, 22935, 27007, 30109, 30420, 33409, 34949, 40283,
        40493, 40549, 47282, 49146,
    ]

    /// Special tokens suppressed at every step, mirroring the reference's
    /// `_get_suppress_tokens` additions beyond the non-speech set.
    static let suppressedSpecialTokens: Set<Int> = [
        WhisperTokenizer.sot,
        WhisperTokenizer.translate,
        WhisperTokenizer.transcribe,
        WhisperTokenizer.startoflm,
        WhisperTokenizer.startofprev,
        WhisperTokenizer.nospeech,
    ]

    /// BPE token ID for a single ASCII space (verified 2026-06-10 via the
    /// compute-non-speech-tokens script). `SuppressBlank` masks this at the
    /// first generation step so the model can't immediately emit whitespace.
    static let spaceToken = 220

    // MARK: - Reference decode defaults

    /// `max_initial_timestamp = 1.0 s` → the first timestamp token may be at
    /// most `<|1.00|>` (index 50 at 0.02 s per step).
    static let maxInitialTimestampIndex = 50

    /// A window whose `<|nospeech|>` probability exceeds this is skipped as
    /// silence — unless the decode's average logprob is confident enough
    /// (`logprobThreshold`), which protects quiet-but-real speech.
    static let noSpeechThreshold: Float = 0.6
    static let logprobThreshold: Float = -1.0

    // MARK: - Timestamp rules (structural half — pure, simulator-testable)

    /// The deterministic part of `ApplyTimestampRules` as half-open ranges of
    /// token IDs to mask, given the tokens sampled so far in this window:
    ///   - `<|notimestamps|>` is always masked (we're in timestamp mode).
    ///   - Timestamps come in pairs: after a segment-closing timestamp the
    ///     next token must be a timestamp or EOT; after a segment-opening
    ///     timestamp the next must be text.
    ///   - Timestamps never decrease (OpenAI semantics — see header note).
    ///   - The first sampled token must be a timestamp ≤ `<|1.00|>`.
    ///
    /// The probabilistic part (force a timestamp when the summed timestamp
    /// probability beats every text token) lives in `decodeWindow` — it needs
    /// the live logits.
    static func timestampRuleMaskRanges(sampled: [Int], nVocab: Int) -> [Range<Int>] {
        let tsBase = WhisperTokenizer.timestampBase
        let eot = WhisperTokenizer.eot
        var ranges: [Range<Int>] = [
            WhisperTokenizer.notimestamps..<(WhisperTokenizer.notimestamps + 1)
        ]

        let lastWasTimestamp = sampled.last.map { $0 >= tsBase } ?? false
        let penultimateWasTimestamp = sampled.count < 2 || sampled[sampled.count - 2] >= tsBase

        if lastWasTimestamp {
            if penultimateWasTimestamp {
                ranges.append(tsBase..<nVocab)  // pair complete → must be text
            } else {
                ranges.append(0..<eot)  // segment-closing → timestamp or EOT only
            }
        }

        if let lastTimestamp = sampled.last(where: { $0 >= tsBase }) {
            // Allow repeating the segment-closing timestamp (that's the pair);
            // otherwise the next timestamp must be strictly greater.
            let bound = (lastWasTimestamp && !penultimateWasTimestamp)
                ? lastTimestamp
                : lastTimestamp + 1
            if bound > tsBase {
                ranges.append(tsBase..<bound)
            }
        }

        if sampled.isEmpty {
            ranges.append(0..<tsBase)  // first token must be a timestamp…
            let lastAllowed = tsBase + maxInitialTimestampIndex
            if lastAllowed + 1 < nVocab {
                ranges.append((lastAllowed + 1)..<nVocab)  // …and an early one
            }
        }

        return ranges
    }

    // MARK: - Window parsing (pure, simulator-testable)

    nonisolated struct ParsedWindow: Equatable {
        /// Tokens whose segments are complete in this window — hand to
        /// `WhisperTokenizer.decode(_:)` (timestamp IDs are ≥ `eot` and get
        /// skipped there).
        let contentTokens: [Int]
        let advance: WindowAdvance
    }

    /// Ports the timestamp-token analysis of the reference seek loop
    /// (`mlx_whisper/transcribe.py`):
    ///   - Consecutive timestamp pairs mark complete segments. The unfinished
    ///     segment after the last pair is *dropped* — the next window restarts
    ///     at the last pair's boundary (`.toTime`) and re-decodes that audio.
    ///   - A single trailing timestamp ("single_timestamp_ending") means no
    ///     speech after it — the whole window is consumed.
    ///   - No pairs at all → keep everything, advance a full window.
    static func parseWindow(_ tokens: [Int]) -> ParsedWindow {
        let tsBase = WhisperTokenizer.timestampBase
        let isTimestamp = tokens.map { $0 >= tsBase }

        let singleTimestampEnding = tokens.count >= 2
            && !isTimestamp[tokens.count - 2]
            && isTimestamp[tokens.count - 1]

        // Indices *after* the first member of each consecutive-timestamp pair
        // (the reference's `consecutive += 1`).
        var sliceEnds: [Int] = []
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) where isTimestamp[i] && isTimestamp[i + 1] {
                sliceEnds.append(i + 1)
            }
        }

        guard !sliceEnds.isEmpty else {
            return ParsedWindow(contentTokens: tokens, advance: .fullWindow)
        }

        if singleTimestampEnding {
            // Pairs + a lone closing timestamp at the very end: everything is
            // a complete segment, and the silence after the last timestamp
            // means the window is exhausted.
            return ParsedWindow(contentTokens: tokens, advance: .fullWindow)
        }

        let lastSliceEnd = sliceEnds[sliceEnds.count - 1]
        let consumed = Array(tokens[..<lastSliceEnd])
        let boundary = WhisperTokenizer.timestampSeconds(tokens[lastSliceEnd - 1]) ?? 0
        return ParsedWindow(contentTokens: consumed, advance: .toTime(boundary))
    }

    // MARK: - Greedy decode (MLX — device only)

    nonisolated struct WindowTokens {
        /// Sampled tokens including timestamp IDs, EOT excluded.
        let tokens: [Int]
        /// Mean logprob per sampled token (incl. EOT), from the masked
        /// distribution — the reference's `avg_logprob`.
        let avgLogprob: Float
        /// P(`<|nospeech|>`) at the SOT position, pre-masking — the
        /// reference's `no_speech_prob`.
        let noSpeechProb: Float
    }

    /// Greedy decode of one 30-s window in timestamp mode. Primes with
    /// `[sot]` (English-only model — no language/task tokens) and applies,
    /// per step: the static suppress sets, first-step blank suppression, the
    /// structural timestamp rules above, and the probabilistic
    /// timestamps-beat-text rule.
    static func decodeWindow(
        model: WhisperModel,
        audioFeatures: MLXArray,
        sampleLen: Int? = nil
    ) -> WindowTokens {
        let nVocab = model.dims.n_vocab
        let nTextCtx = model.dims.n_text_ctx
        let maxLen = sampleLen ?? (nTextCtx / 2)
        let eot = WhisperTokenizer.eot
        let tsBase = WhisperTokenizer.timestampBase

        let suppressMask = makeMask(nVocab: nVocab, ids: nonSpeechTokens.union(suppressedSpecialTokens))
        let blankMask = makeMask(nVocab: nVocab, ids: [spaceToken, eot])

        var inputs = MLXArray(
            WhisperTokenizer.sotSequence.map { Int32($0) },
            [1, WhisperTokenizer.sotSequence.count]
        )

        var kvCache: [WhisperLayerKVCache]? = nil
        var resultIDs: [Int] = []
        resultIDs.reserveCapacity(maxLen)
        var sumLogprob: Float = 0
        var noSpeechProb: Float = 0

        for step in 0..<maxLen {
            // Bail if we've blown past the decoder's positional embedding budget.
            let cachedLen = kvCache.flatMap { $0[0].0?.0.shape[1] } ?? 0
            if cachedLen + inputs.shape[1] > nTextCtx { break }

            let (logits, newCache) = model.logits(
                tokens: inputs,
                audioFeatures: audioFeatures,
                kvCache: kvCache
            )
            kvCache = newCache

            // Slice to the last position: `logits[:, -1]` → shape [B, vocab].
            let lastIdx = logits.shape[1] - 1
            var lastLogits = logits[0..., lastIdx].asType(.float32)

            if step == 0 {
                // The first logits row is the SOT position — read
                // P(<|nospeech|>) there, before any masking.
                let probs = softmax(lastLogits, axis: -1)
                noSpeechProb = probs[0, WhisperTokenizer.nospeech].item(Float.self)
            }

            lastLogits = lastLogits + suppressMask
            if step == 0 {
                lastLogits = lastLogits + blankMask
            }
            for range in timestampRuleMaskRanges(sampled: resultIDs, nVocab: nVocab) {
                lastLogits[0..., range.lowerBound..<range.upperBound] = MLXArray(-Float.infinity)
            }

            // Probabilistic rule: if the summed timestamp probability beats
            // every individual text token, force a timestamp.
            let logprobs = lastLogits - logSumExp(lastLogits, axis: -1, keepDims: true)
            let timestampLogprob = logSumExp(logprobs[0..., tsBase...], axis: -1)
            let maxTextLogprob = logprobs[0..., ..<tsBase].max(axis: -1)
            eval(timestampLogprob, maxTextLogprob)
            if timestampLogprob[0].item(Float.self) > maxTextLogprob[0].item(Float.self) {
                lastLogits[0..., ..<tsBase] = MLXArray(-Float.infinity)
            }

            let finalLogprobs = lastLogits - logSumExp(lastLogits, axis: -1, keepDims: true)
            let nextToken = finalLogprobs.argMax(axis: -1)
            eval(nextToken)
            let nextID = Int(nextToken[0].item(Int32.self))
            sumLogprob += finalLogprobs[0, nextID].item(Float.self)

            if nextID == eot { break }
            resultIDs.append(nextID)

            // Subsequent steps feed only the newly-emitted token — the KV
            // cache holds the prior context.
            inputs = MLXArray([Int32(nextID)], [1, 1])
        }

        // Reference: `avg_logprob = sum_logprobs / (len(tokens) + 1)` where
        // the sum includes EOT but the count doesn't.
        let avgLogprob = sumLogprob / Float(resultIDs.count + 1)
        return WindowTokens(tokens: resultIDs, avgLogprob: avgLogprob, noSpeechProb: noSpeechProb)
    }

    // MARK: - Mask helpers

    /// Build an additive logits mask: 0 at allowed positions, `-inf` at
    /// suppressed positions. Added to logits at the appropriate step.
    private static func makeMask(nVocab: Int, ids: Set<Int>) -> MLXArray {
        var values = [Float](repeating: 0, count: nVocab)
        for id in ids where id >= 0 && id < nVocab {
            values[id] = -.infinity
        }
        return MLXArray(values)
    }
}
