import Foundation
import MLX

/// Whisper's greedy decode loop, ported from the minimal subset of
/// `mlx_whisper/decoding.py` needed for English-only, no-timestamps, no-beam,
/// no-temperature-fallback inference. The full Python file is ~741 lines;
/// this is ~120 because we drop beam search, sampling, language detection,
/// `ApplyTimestampRules`, and the temperature retry loop.
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

    /// BPE token ID for a single ASCII space (verified 2026-06-10 via the
    /// compute-non-speech-tokens script). `SuppressBlank` masks this at the
    /// first generation step so the model can't immediately emit whitespace.
    static let spaceToken = 220

    // MARK: - Greedy decode

    /// Run greedy decode against pre-encoded audio features. Returns the
    /// content token IDs (special tokens stripped). Caller is expected to
    /// pass the result to `WhisperTokenizer.decode(_:)` to get a string.
    ///
    /// - Parameters:
    ///   - model: a loaded `WhisperModel`.
    ///   - audioFeatures: encoder output `[1, n_audio_ctx, n_audio_state]`.
    ///   - sampleLen: maximum number of generation steps. Defaults to
    ///     `n_text_ctx / 2 = 224`, matching the Python reference.
    static func greedyDecode(
        model: WhisperModel,
        audioFeatures: MLXArray,
        sampleLen: Int? = nil
    ) -> [Int] {
        let nVocab = model.dims.n_vocab
        let nTextCtx = model.dims.n_text_ctx
        let maxLen = sampleLen ?? (nTextCtx / 2)
        let eot = WhisperTokenizer.eot

        // Pre-build the static suppress mask (applied every step).
        let suppressMask = makeMask(nVocab: nVocab, ids: nonSpeechTokens)
        // First-step-only mask: forbid space + eot so the model can't start
        // with whitespace or terminate immediately.
        let blankMask = makeMask(nVocab: nVocab, ids: [spaceToken, eot])

        // Prime with [sot, notimestamps]. Batch dim = 1.
        var inputs = MLXArray(
            WhisperTokenizer.primeSequence.map { Int32($0) },
            [1, WhisperTokenizer.primeSequence.count]
        )

        var kvCache: [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)]? = nil
        var resultIDs: [Int] = []
        resultIDs.reserveCapacity(maxLen)

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
            var lastLogits = logits[0..., lastIdx]
            lastLogits = lastLogits + suppressMask
            if step == 0 {
                lastLogits = lastLogits + blankMask
            }

            let nextToken = lastLogits.argMax(axis: -1)
            eval(nextToken)
            let id = nextToken[0].item(Int32.self)
            let nextID = Int(id)

            if nextID == eot { break }
            resultIDs.append(nextID)

            // Subsequent steps feed only the newly-emitted token — the KV
            // cache holds the prior context.
            inputs = MLXArray([Int32(nextID)], [1, 1])
        }

        return resultIDs
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
