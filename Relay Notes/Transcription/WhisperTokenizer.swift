import Foundation

/// Whisper BPE tokenizer — **decode-only**.
///
/// Greedy inference does not need a BPE *encoder*: the decoder primes with
/// fixed special-token IDs (`sot`, `notimestamps`) and emits IDs, which we
/// only ever need to turn back into text. That collapses the ~398-line Python
/// `mlx_whisper/tokenizer.py` (which wraps `tiktoken`) to the ~80 lines here.
///
/// Vocab layout (English-only build, `gpt2.tiktoken`):
/// - Ranks 0..50255: raw-byte BPE entries from `gpt2.tiktoken`
/// - 50256 `<|endoftext|>`
/// - 50257 `<|startoftranscript|>`
/// - 50258..50356 language tokens (`<|en|>` through 98 others, reserved even
///   in the English-only build — `get_encoding("gpt2", num_languages=99)` still
///   appends them)
/// - 50357 `<|translate|>`
/// - 50358 `<|transcribe|>`
/// - 50359 `<|startoflm|>`
/// - 50360 `<|startofprev|>`
/// - 50361 `<|nospeech|>`
/// - 50362 `<|notimestamps|>`
/// - 50363..51863 timestamp tokens (`<|0.00|>` through `<|30.00|>`, 1501 entries)
nonisolated final class WhisperTokenizer: Sendable {

    /// Number of raw-byte BPE entries in the English-only vocab.
    static let nVocabBPE = 50_256

    // MARK: - Special token IDs (English-only build)

    static let eot           = 50_256
    static let sot           = 50_257
    static let langTokenBase = 50_258
    static let en            = 50_258
    static let translate     = 50_357
    static let transcribe    = 50_358
    static let startoflm     = 50_359
    static let startofprev   = 50_360
    static let nospeech      = 50_361
    static let notimestamps  = 50_362
    static let timestampBase = 50_363

    /// Prime sequence the decoder is forced to emit before generating content,
    /// for the English-only, no-timestamps configuration.
    static let primeSequence: [Int] = [sot, notimestamps]

    // MARK: - Errors

    enum Error: Swift.Error {
        case vocabNotFound
        case vocabReadFailed(any Swift.Error)
        case vocabParseFailed(line: Int)
        case vocabIncomplete(seen: Int, expected: Int)
    }

    // MARK: - State

    /// Index = token ID, value = the raw bytes that ID maps to. Length is
    /// always `nVocabBPE` after a successful init.
    private let idToBytes: [Data]

    // MARK: - Init

    init() throws {
        guard let url = Bundle.main.url(forResource: "gpt2", withExtension: "tiktoken") else {
            throw Error.vocabNotFound
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw Error.vocabReadFailed(error)
        }

        var bytes = Array<Data>(repeating: Data(), count: Self.nVocabBPE)
        var seen = Set<Int>()

        for (lineIdx, rawLine) in raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let decoded = Data(base64Encoded: String(parts[0])),
                  let rank = Int(parts[1]),
                  rank >= 0, rank < Self.nVocabBPE
            else {
                throw Error.vocabParseFailed(line: lineIdx + 1)
            }
            bytes[rank] = decoded
            seen.insert(rank)
        }

        guard seen.count == Self.nVocabBPE else {
            throw Error.vocabIncomplete(seen: seen.count, expected: Self.nVocabBPE)
        }
        self.idToBytes = bytes
    }

    // MARK: - Decode

    /// Decode a sequence of token IDs to text. Special tokens (ID ≥ `eot`) are
    /// silently skipped — the greedy loop is expected to terminate on `eot`
    /// itself, but the filter is here as a safety net.
    ///
    /// Multi-byte UTF-8 sequences split across BPE tokens are handled correctly
    /// because we concatenate all bytes first and decode once at the end.
    /// Invalid sequences (e.g. a truncated emoji at the tail) decode lossily —
    /// `String(decoding:as:)` substitutes U+FFFD rather than dropping the run.
    func decode(_ ids: [Int]) -> String {
        var bytes = Data()
        bytes.reserveCapacity(ids.count * 4)
        for id in ids {
            if id >= Self.eot { continue }
            guard id >= 0, id < idToBytes.count else { continue }
            bytes.append(idToBytes[id])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
