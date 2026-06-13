import Foundation

/// Parsed `config.json` for an NVIDIA Parakeet TDT model (`nemo_version 2.4.0rc0`,
/// `EncDecRNNTBPEModel`), as shipped by `mlx-community/parakeet-tdt-0.6b-v2`.
///
/// Ported from the config structs in `FluidInference/swift-parakeet-mlx` (MIT)
/// and cross-checked against `senstella/parakeet-mlx` (Apache-2.0, the Python
/// reference). Trimmed to the inference subset — training/aug/optimizer keys in
/// the source JSON are ignored (the explicit `CodingKeys` below only name what
/// the encoder / decoder / joint / featurizer actually consume).
///
/// Field names mirror the JSON's `snake_case` via `CodingKeys`, matching the
/// convention used by `ModelDimensions` on the Whisper side.
///
/// **What differs from Whisper (read before reusing the Whisper front-end):**
/// `n_fft 512` (not 400), `features 128` mels (not 80), `normalize "per_feature"`
/// (per-mel z-score, not Whisper's global `(logmel+4)/4` clamp), `window_size`
/// 0.025 s = 400 samples ≠ `n_fft` (the window is zero-padded to 512). This v2
/// checkpoint carries **no `preemph` and no `mag_power`** keys — so preemphasis
/// is off here (kept optional, not assumed 0.97) and the power spectrum exponent
/// defaults to 2.0.
nonisolated struct ParakeetTDTConfig: Codable, Sendable {
    let preprocessor: ParakeetPreprocessConfig
    let encoder: ParakeetConformerConfig
    let decoder: ParakeetDecoderConfig
    let joint: ParakeetJointConfig
    let decoding: ParakeetDecodingConfig

    enum CodingKeys: String, CodingKey {
        case preprocessor, encoder, decoder, joint, decoding
    }
}

// MARK: - Preprocessor (mel front-end)

nonisolated struct ParakeetPreprocessConfig: Codable, Sendable {
    let sampleRate: Int
    /// `"per_feature"` for this model — per-mel-bin mean/variance normalization
    /// across time. The featurizer (T2.1b) branches on this.
    let normalize: String
    /// Window length in **seconds** (0.025 → 400 samples at 16 kHz).
    let windowSize: Float
    /// Hop / stride in **seconds** (0.01 → 160 samples at 16 kHz).
    let windowStride: Float
    let window: String
    /// Number of mel filterbanks (128 here).
    let features: Int
    let nFFT: Int
    /// Training-time noise; disabled at inference. Stored for completeness.
    let dither: Float?
    let padTo: Int?
    let padValue: Float?
    /// Pre-emphasis coefficient. **Absent (nil) for parakeet-tdt-0.6b-v2** — do
    /// not assume 0.97; apply only when present.
    let preemph: Float?

    /// Power-spectrum exponent. Not present in this checkpoint's JSON; NeMo's
    /// default is 2.0 (power spectrum). Held as a constant, not decoded.
    let magPower: Float = 2.0

    /// Window length in samples: `window_size × sample_rate`.
    var winLength: Int { Int(windowSize * Float(sampleRate)) }
    /// Hop length in samples: `window_stride × sample_rate`.
    var hopLength: Int { Int(windowStride * Float(sampleRate)) }

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case normalize
        case windowSize = "window_size"
        case windowStride = "window_stride"
        case window
        case features
        case nFFT = "n_fft"
        case dither
        case padTo = "pad_to"
        case padValue = "pad_value"
        case preemph
    }
}

// MARK: - Encoder (FastConformer)

nonisolated struct ParakeetConformerConfig: Codable, Sendable {
    let featIn: Int
    let nLayers: Int
    let dModel: Int
    let nHeads: Int
    let ffExpansionFactor: Int
    /// Time-axis reduction from the subsampling stem (8 here → one frame per
    /// `subsamplingFactor × hopLength` input samples).
    let subsamplingFactor: Int
    /// `"rel_pos"` — relative-positional multi-head attention.
    let selfAttentionModel: String
    /// `"dw_striding"` — depthwise-separable strided conv subsampling.
    let subsampling: String
    let convKernelSize: Int
    let subsamplingConvChannels: Int
    let posEmbMaxLen: Int
    /// `false` for this checkpoint — Linear/Conv layers omit bias.
    let useBias: Bool
    /// Whether the encoder scales embeddings by √dModel. `false` here.
    let xscaling: Bool

    enum CodingKeys: String, CodingKey {
        case featIn = "feat_in"
        case nLayers = "n_layers"
        case dModel = "d_model"
        case nHeads = "n_heads"
        case ffExpansionFactor = "ff_expansion_factor"
        case subsamplingFactor = "subsampling_factor"
        case selfAttentionModel = "self_attention_model"
        case subsampling
        case convKernelSize = "conv_kernel_size"
        case subsamplingConvChannels = "subsampling_conv_channels"
        case posEmbMaxLen = "pos_emb_max_len"
        case useBias = "use_bias"
        case xscaling
    }
}

// MARK: - Decoder (prediction network)

nonisolated struct ParakeetPredNetConfig: Codable, Sendable {
    let predHidden: Int
    let predRNNLayers: Int

    enum CodingKeys: String, CodingKey {
        case predHidden = "pred_hidden"
        case predRNNLayers = "pred_rnn_layers"
    }
}

nonisolated struct ParakeetDecoderConfig: Codable, Sendable {
    let blankAsPad: Bool
    let vocabSize: Int
    let prednet: ParakeetPredNetConfig

    enum CodingKeys: String, CodingKey {
        case blankAsPad = "blank_as_pad"
        case vocabSize = "vocab_size"
        case prednet
    }
}

// MARK: - Joint network

nonisolated struct ParakeetJointNetConfig: Codable, Sendable {
    let jointHidden: Int
    let activation: String
    let encoderHidden: Int
    let predHidden: Int

    enum CodingKeys: String, CodingKey {
        case jointHidden = "joint_hidden"
        case activation
        case encoderHidden = "encoder_hidden"
        case predHidden = "pred_hidden"
    }
}

nonisolated struct ParakeetJointConfig: Codable, Sendable {
    let numClasses: Int
    /// The full id→token-piece table (1024 entries). Decode is `vocabulary[id]`
    /// with `"▁"` → space — no SentencePiece runtime needed for transcription.
    let vocabulary: [String]
    let jointnet: ParakeetJointNetConfig
    /// Number of TDT duration outputs appended after the vocab logits (5 here:
    /// the joint output's last dim is `vocabSize + 1 (blank) + numExtraOutputs`).
    let numExtraOutputs: Int

    enum CodingKeys: String, CodingKey {
        case numClasses = "num_classes"
        case vocabulary
        case jointnet
        case numExtraOutputs = "num_extra_outputs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        numClasses = try c.decode(Int.self, forKey: .numClasses)
        vocabulary = try c.decode([String].self, forKey: .vocabulary)
        jointnet = try c.decode(ParakeetJointNetConfig.self, forKey: .jointnet)
        numExtraOutputs = try c.decodeIfPresent(Int.self, forKey: .numExtraOutputs) ?? 0
    }
}

// MARK: - Decoding (TDT greedy)

nonisolated struct ParakeetDecodingConfig: Codable, Sendable {
    /// Must be `"tdt"` — the token-and-duration transducer decode path.
    let modelType: String
    /// Frame-advance choices the duration head selects among (`[0,1,2,3,4]`).
    let durations: [Int]
    /// Guard against duration-0 loops; defaults to 10 when absent from JSON.
    let maxSymbols: Int

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case durations
        case greedy
    }

    private enum GreedyKeys: String, CodingKey {
        case maxSymbols = "max_symbols"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decode(String.self, forKey: .modelType)
        durations = try c.decode([Int].self, forKey: .durations)
        if let greedy = try? c.nestedContainer(keyedBy: GreedyKeys.self, forKey: .greedy) {
            maxSymbols = (try? greedy.decodeIfPresent(Int.self, forKey: .maxSymbols)) ?? 10
        } else {
            maxSymbols = 10
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelType, forKey: .modelType)
        try c.encode(durations, forKey: .durations)
        var greedy = c.nestedContainer(keyedBy: GreedyKeys.self, forKey: .greedy)
        try greedy.encode(maxSymbols, forKey: .maxSymbols)
    }
}

// MARK: - Load

extension ParakeetTDTConfig {
    /// Decode from a `config.json` on disk.
    static func load(from url: URL) throws -> ParakeetTDTConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ParakeetTDTConfig.self, from: data)
    }
}
