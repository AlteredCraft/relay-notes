import Foundation
import MLX
import MLXNN

/// Whisper encoder + decoder + KV cache, ported from
/// `ml-explore/mlx-examples/whisper/mlx_whisper/whisper.py` to mlx-swift.
///
/// Notable differences from the Python reference:
///   - mlx-swift's built-in `MultiHeadAttention` uses key names
///     `query_proj`/`key_proj`/`value_proj`/`out_proj` and a single bias flag.
///     The Whisper safetensors uses `attn.{query,key,value,out}` with per-projection
///     bias control (`key` has no bias). Hence the custom `WhisperAttention` below.
///   - Word-timestamp alignment heads, `forward_with_cross_qk`, and
///     `set_alignment_heads` are skipped — they aren't needed for greedy
///     transcription.

// MARK: - Config

/// Whisper model dimensions, parsed from the HF model's `config.json`.
/// Field names use Python `snake_case` to match the JSON keys exactly.
nonisolated struct ModelDimensions: Sendable, Codable {
    let n_mels: Int
    let n_audio_ctx: Int
    let n_audio_state: Int
    let n_audio_head: Int
    let n_audio_layer: Int
    let n_vocab: Int
    let n_text_ctx: Int
    let n_text_state: Int
    let n_text_head: Int
    let n_text_layer: Int

    static func load(from location: ModelLocation) throws -> ModelDimensions {
        guard let url = location.fileURL(name: "config", ext: "json") else {
            throw WhisperModelError.configNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModelDimensions.self, from: data)
    }
}

enum WhisperModelError: Error {
    case configNotFound
    case weightsNotFound
    case weightsLoadFailed(any Error)
}

// MARK: - Sinusoidal positional embedding

/// Pre-computes the sinusoidal positional embedding used by the encoder.
/// Output shape: `[length, channels]`.
nonisolated func sinusoids(length: Int, channels: Int, maxTimescale: Float = 10_000) -> MLXArray {
    precondition(channels % 2 == 0, "sinusoid channels must be even")
    let half = channels / 2
    let logTimescaleIncrement = log(maxTimescale) / Float(half - 1)
    let invTimescales = exp(-logTimescaleIncrement * arange(half, dtype: .float32))
    let scaledTime = expandedDimensions(arange(length, dtype: .float32), axis: 1)
        * expandedDimensions(invTimescales, axis: 0)
    return concatenated([sin(scaledTime), cos(scaledTime)], axis: 1)
}

// MARK: - Multi-head attention (Whisper-flavored)

/// Whisper attention with KV caching for both self- and cross-attention.
///
/// `kvCache` semantics match the Python reference:
///   - **Self-attention** (`xa == nil`): K/V are computed from `x` and
///     concatenated with the cached K/V along the sequence axis. Cache grows
///     by one step per call.
///   - **Cross-attention** (`xa != nil`):
///     - First call with `kvCache == nil`: K/V are computed from `xa` (the
///       encoder output) and returned for caching.
///     - Subsequent calls with `kvCache != nil`: K/V are reused unchanged.
nonisolated final class WhisperAttention: Module {
    let nHead: Int
    @ModuleInfo var query: Linear
    @ModuleInfo var key: Linear
    @ModuleInfo var value: Linear
    @ModuleInfo var out: Linear

    nonisolated init(nState: Int, nHead: Int) {
        self.nHead = nHead
        self._query.wrappedValue = Linear(nState, nState, bias: true)
        self._key.wrappedValue = Linear(nState, nState, bias: false)
        self._value.wrappedValue = Linear(nState, nState, bias: true)
        self._out.wrappedValue = Linear(nState, nState, bias: true)
        super.init()
    }

    func forward(
        _ x: MLXArray,
        xa: MLXArray? = nil,
        mask: MLXArray? = nil,
        kvCache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        let q = query(x)
        let k: MLXArray
        let v: MLXArray
        if xa == nil {
            // Self-attention: compute new K/V, extend cache.
            var newK = key(x)
            var newV = value(x)
            if let (cachedK, cachedV) = kvCache {
                newK = concatenated([cachedK, newK], axis: 1)
                newV = concatenated([cachedV, newV], axis: 1)
            }
            k = newK
            v = newV
        } else if let (cachedK, cachedV) = kvCache {
            // Cross-attention, cache hit: reuse encoder K/V.
            k = cachedK
            v = cachedV
        } else {
            // Cross-attention, cache miss: compute K/V from encoder output once.
            k = key(xa!)
            v = value(xa!)
        }

        let wv = qkvAttention(q: q, k: k, v: v, mask: mask)
        return (out(wv), (k, v))
    }

    private func qkvAttention(
        q: MLXArray,
        k: MLXArray,
        v: MLXArray,
        mask: MLXArray? = nil
    ) -> MLXArray {
        let (nBatch, nCtx, nState) = (q.shape[0], q.shape[1], q.shape[2])
        let headDim = nState / nHead
        let scale = pow(Float(headDim), -0.25)

        // q: [B, Tq, n_state] → [B, n_head, Tq, head_dim]
        let qReshaped = q
            .reshaped(nBatch, nCtx, nHead, headDim)
            .transposed(0, 2, 1, 3) * scale
        // k: [B, Tk, n_state] → [B, n_head, head_dim, Tk] (note transposed for q @ k)
        let kReshaped = k
            .reshaped(k.shape[0], k.shape[1], nHead, headDim)
            .transposed(0, 2, 3, 1) * scale
        // v: [B, Tk, n_state] → [B, n_head, Tk, head_dim]
        let vReshaped = v
            .reshaped(v.shape[0], v.shape[1], nHead, headDim)
            .transposed(0, 2, 1, 3)

        var qk = qReshaped.matmul(kReshaped)        // [B, n_head, Tq, Tk]
        if let mask {
            // Python: `qk = qk + mask[:n_ctx, :n_ctx]` — slice to query length.
            qk = qk + mask[..<nCtx, ..<nCtx]
        }

        let w = softmax(qk, axis: -1, precise: true)
        let attn = w.matmul(vReshaped)              // [B, n_head, Tq, head_dim]
        return attn
            .transposed(0, 2, 1, 3)                 // [B, Tq, n_head, head_dim]
            .reshaped(nBatch, nCtx, nState)
    }
}

// MARK: - Residual attention block

/// Self-attention + (optional) cross-attention + MLP, with pre-layernorms.
/// `kvCache` is `(selfAttnKV, crossAttnKV)` — both optional per call.
nonisolated final class ResidualAttentionBlock: Module {
    @ModuleInfo var attn: WhisperAttention
    @ModuleInfo(key: "attn_ln") var attnLn: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttn: WhisperAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttnLn: LayerNorm?
    @ModuleInfo var mlp1: Linear
    @ModuleInfo var mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpLn: LayerNorm

    nonisolated init(nState: Int, nHead: Int, crossAttention: Bool) {
        self._attn.wrappedValue = WhisperAttention(nState: nState, nHead: nHead)
        self._attnLn.wrappedValue = LayerNorm(dimensions: nState)
        if crossAttention {
            self._crossAttn.wrappedValue = WhisperAttention(nState: nState, nHead: nHead)
            self._crossAttnLn.wrappedValue = LayerNorm(dimensions: nState)
        }
        let nMLP = nState * 4
        self._mlp1.wrappedValue = Linear(nState, nMLP, bias: true)
        self._mlp2.wrappedValue = Linear(nMLP, nState, bias: true)
        self._mlpLn.wrappedValue = LayerNorm(dimensions: nState)
        super.init()
    }

    func forward(
        _ x: MLXArray,
        xa: MLXArray? = nil,
        mask: MLXArray? = nil,
        kvCache: ((MLXArray, MLXArray)?, (MLXArray, MLXArray)?) = (nil, nil)
    ) -> (MLXArray, ((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)) {
        let (selfKV, crossKV) = kvCache

        let (y, newSelfKV) = attn.forward(attnLn(x), mask: mask, kvCache: selfKV)
        var x = x + y

        var newCrossKV: (MLXArray, MLXArray)? = crossKV
        if let crossAttn, let crossAttnLn {
            let (y2, ckv) = crossAttn.forward(crossAttnLn(x), xa: xa, kvCache: crossKV)
            newCrossKV = ckv
            x = x + y2
        }

        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return (x, (newSelfKV, newCrossKV))
    }
}

// MARK: - Audio encoder

/// Mel input → encoded audio features for cross-attention.
/// Two stride-{1,2} Conv1d stems halve the time axis (3000 → 1500), then
/// `n_audio_layer` residual self-attention blocks operate on the sinusoidal-
/// position-embedded features.
nonisolated final class AudioEncoder: Module {
    @ModuleInfo var conv1: Conv1d
    @ModuleInfo var conv2: Conv1d
    @ParameterInfo(key: "_positional_embedding") var positionalEmbedding: MLXArray
    let blocks: [ResidualAttentionBlock]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm

    nonisolated init(nMels: Int, nCtx: Int, nState: Int, nHead: Int, nLayer: Int) {
        self._conv1.wrappedValue = Conv1d(
            inputChannels: nMels, outputChannels: nState, kernelSize: 3, padding: 1)
        self._conv2.wrappedValue = Conv1d(
            inputChannels: nState, outputChannels: nState, kernelSize: 3, stride: 2, padding: 1)
        self._positionalEmbedding.wrappedValue = sinusoids(length: nCtx, channels: nState)
        self.blocks = (0..<nLayer).map { _ in
            ResidualAttentionBlock(nState: nState, nHead: nHead, crossAttention: false)
        }
        self._lnPost.wrappedValue = LayerNorm(dimensions: nState)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = gelu(conv1(x))
        x = gelu(conv2(x))
        // Python: `assert x.shape[1:] == self._positional_embedding.shape`
        x = x + positionalEmbedding

        for block in blocks {
            (x, _) = block.forward(x)
        }
        return lnPost(x)
    }
}

// MARK: - Text decoder

/// Token IDs + encoder features → logits.
/// Implements KV-cache-aware autoregressive decoding: caller threads the
/// per-block `((selfKV, crossKV))` tuple through successive calls.
nonisolated final class TextDecoder: Module {
    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo(key: "positional_embedding") var positionalEmbedding: MLXArray
    let blocks: [ResidualAttentionBlock]
    let ln: LayerNorm

    /// Pre-built additive causal mask used for self-attention in every block.
    /// Stored as a non-tracked constant so it doesn't show up in `parameters()`.
    private let mask: MLXArray

    nonisolated init(nVocab: Int, nCtx: Int, nState: Int, nHead: Int, nLayer: Int) {
        self._tokenEmbedding.wrappedValue = Embedding(embeddingCount: nVocab, dimensions: nState)
        self._positionalEmbedding.wrappedValue = MLX.zeros([nCtx, nState], dtype: .float32)
        self.blocks = (0..<nLayer).map { _ in
            ResidualAttentionBlock(nState: nState, nHead: nHead, crossAttention: true)
        }
        self.ln = LayerNorm(dimensions: nState)
        self.mask = MultiHeadAttention.createAdditiveCausalMask(nCtx)
        super.init()
    }

    /// Run the decoder for one step (or the full prime sequence).
    /// `kvCache` is the per-block tuple from the previous call (or `nil` for
    /// the first call). The returned cache should be threaded through to the next call.
    func callAsFunction(
        _ x: MLXArray,
        xa: MLXArray,
        kvCache: [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)]? = nil
    ) -> (MLXArray, [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)]) {
        // Position offset = number of previously-cached self-attn keys.
        let offset: Int
        if let kvCache, let firstSelfKV = kvCache[0].0 {
            // K shape is [B, T_cache, n_state]; Python reads `kv_cache[0][0][0].shape[1]`.
            offset = firstSelfKV.0.shape[1]
        } else {
            offset = 0
        }
        let len = x.shape[x.shape.count - 1]
        var y = tokenEmbedding(x) + positionalEmbedding[offset..<(offset + len)]

        var newCache: [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)] =
            kvCache ?? Array(repeating: (nil, nil), count: blocks.count)

        for (i, block) in blocks.enumerated() {
            let (out, kv) = block.forward(y, xa: xa, mask: mask, kvCache: newCache[i])
            y = out
            newCache[i] = kv
        }
        y = ln(y)
        return (tokenEmbedding.asLinear(y), newCache)
    }
}

// MARK: - Top-level Whisper

/// Encoder + decoder + helpers. Construct via `WhisperModel.loadFromBundle()`
/// which reads `config.json` + `weights.safetensors` from the app bundle.
nonisolated final class WhisperModel: Module {
    let dims: ModelDimensions
    @ModuleInfo var encoder: AudioEncoder
    @ModuleInfo var decoder: TextDecoder

    nonisolated init(dims: ModelDimensions) {
        self.dims = dims
        self._encoder.wrappedValue = AudioEncoder(
            nMels: dims.n_mels,
            nCtx: dims.n_audio_ctx,
            nState: dims.n_audio_state,
            nHead: dims.n_audio_head,
            nLayer: dims.n_audio_layer)
        self._decoder.wrappedValue = TextDecoder(
            nVocab: dims.n_vocab,
            nCtx: dims.n_text_ctx,
            nState: dims.n_text_state,
            nHead: dims.n_text_head,
            nLayer: dims.n_text_layer)
        super.init()
    }

    /// Encode a mel spectrogram into audio features for cross-attention.
    /// `mel` shape: `[batch, n_audio_ctx * 2, n_mels]` = `[B, 3000, 80]`.
    func embedAudio(_ mel: MLXArray) -> MLXArray {
        encoder(mel)
    }

    /// Compute logits for the next token(s). Greedy callers feed a single token
    /// at a time after the prime sequence; the cache carries previous K/V.
    func logits(
        tokens: MLXArray,
        audioFeatures: MLXArray,
        kvCache: [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)]? = nil
    ) -> (MLXArray, [((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)]) {
        decoder(tokens, xa: audioFeatures, kvCache: kvCache)
    }

    // MARK: Load

    /// Loads the model with weights from the given location.
    /// **Note:** in dev (`.bundled`) the weights must be present (run
    /// `scripts/fetch-whisper-model.sh` once). The `weights.safetensors` file
    /// is gitignored. In prod (`.directory`) T1.2b's download manager places
    /// the file in Application Support.
    static func load(from location: ModelLocation) throws -> WhisperModel {
        let dims = try ModelDimensions.load(from: location)
        let model = WhisperModel(dims: dims)
        guard let weightsURL = location.fileURL(name: "weights", ext: "safetensors") else {
            throw WhisperModelError.weightsNotFound
        }
        let flat: [String: MLXArray]
        do {
            flat = try loadArrays(url: weightsURL)
        } catch {
            throw WhisperModelError.weightsLoadFailed(error)
        }
        // Drop the `alignment_heads` entry — we don't port word-timestamp
        // alignment. The remaining keys map cleanly into the `encoder.*` /
        // `decoder.*` tree.
        let filtered = flat.filter { $0.key != "alignment_heads" }
        let params = ModuleParameters.unflattened(filtered)
        model.update(parameters: params)
        return model
    }
}
