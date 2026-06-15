import Foundation

/// How long a single cleanup decode is allowed to run, as a hard `maxTokens` cap
/// derived from the input length (GH #12).
///
/// `MLXLanguageModel.clean` otherwise runs with no `maxTokens`, so generation is
/// bounded only by the model emitting an EOS token. Degenerate repetition — a known
/// failure mode of small quantized models — could then decode unbounded, and during
/// that window the UI only shows a spinner. Cleanup output is ~the size of the input
/// transcript, so a generous multiple of the input's token estimate is comfortably
/// above any legitimate result while still self-terminating a runaway.
///
/// Pure integer math (no MLX) so it's simulator-testable and provider-neutral — a
/// future cloud `LanguageModel` can reuse it.
enum CleanupTokenBudget {

    /// Rough chars-per-token for English prose under a BPE/SentencePiece tokenizer.
    /// Only an order-of-magnitude estimate is needed; `outputMultiplier` carries the
    /// real safety margin, so the exact constant isn't load-bearing.
    static let approxCharactersPerToken = 4

    /// Headroom over the input estimate. Cleanup adds punctuation/structure and can
    /// lightly re-expand text, but never balloons — 4× is far above any legitimate
    /// cleanup yet still caps a repetition loop well short of "unbounded".
    static let outputMultiplier = 4

    /// Floor so very short notes still get room to be cleaned — a one-line note must
    /// not be handed a near-zero budget that truncates a legitimate result.
    static let minimumTokens = 512

    /// The hard `maxTokens` cap for cleaning a raw transcript `characters` long.
    /// Never below `minimumTokens`; scales with input above the floor's break-even.
    static func maxTokens(forRawCharacterCount characters: Int) -> Int {
        let estimatedInputTokens = max(0, characters) / approxCharactersPerToken
        return max(minimumTokens, estimatedInputTokens * outputMultiplier)
    }
}
