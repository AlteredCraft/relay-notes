import Foundation

/// Vocabulary decode for Parakeet TDT — id → text. Ports
/// `senstella/parakeet-mlx`'s `tokenizer.py::decode` (and the Swift reference's
/// `Tokenizer.decode`): no SentencePiece runtime needed, the id→piece table is
/// `config.joint.vocabulary` (1024 entries) and the `▁` marker becomes a space.
///
/// `nonisolated` free function — pure string work, no MLX, no isolation.
nonisolated func parakeetDecodeTokens(_ ids: [Int], vocabulary: [String]) -> String {
    ids.compactMap { id -> String? in
        guard id >= 0 && id < vocabulary.count else { return nil }
        return vocabulary[id].replacingOccurrences(of: "\u{2581}", with: " ")  // "▁" → space
    }.joined()
}
