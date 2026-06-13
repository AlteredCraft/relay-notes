import Foundation
import MLX
import MLXNN

/// FastConformer encoder for Parakeet TDT — mel features → `[B, T/8, dModel]`
/// acoustic embeddings. Ports `senstella/parakeet-mlx`'s `conformer.py`
/// (`DwStridingSubsampling`, `ConformerBlock`, `Convolution`, `FeedForward`,
/// `Conformer`) to mlx-swift, cross-checked against `FluidInference/swift-parakeet-mlx`.
///
/// **Weight loading needs no key remapper and no conv transpose.** The
/// `@ModuleInfo`/`@ParameterInfo` keys below are the **snake_case safetensors
/// keys** verbatim (the Whisper port's convention), and the mlx-community
/// safetensors already store conv weights in MLX's channel-last layout
/// (`[out, kernel…, in/groups]`) — the reference loads them with no transpose
/// (`let transformedWeights = weights`). So `loadArrays` → strip `encoder.` →
/// `unflattened` → `update` is the whole mapping.
///
/// **Loaded by the incremental cast-and-release path (§3.1 / plan.T2.md):**
/// ``load(weightsURL:config:)`` casts each F32 tensor to bf16 and drops its F32
/// source before the next, with `Memory.cacheLimit = 0` so freed buffers return
/// to the OS — never holding the full F32 set and the bf16 copy at once. MLX
/// laziness means the modules' random init weights are never materialized before
/// `update` replaces them, so construction stays cheap.
///
/// `use_bias=false` for the encoder → the Linear/Conv projections carry no bias;
/// only the conv `batch_norm` and the LayerNorms have weight+bias.

// MARK: - Feed-forward (macaron half-residual)

nonisolated final class ParakeetFeedForward: Module {
    @ModuleInfo(key: "linear1") var linear1: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear

    nonisolated init(dModel: Int, dFF: Int, bias: Bool) {
        self._linear1.wrappedValue = Linear(dModel, dFF, bias: bias)
        self._linear2.wrappedValue = Linear(dFF, dModel, bias: bias)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(silu(linear1(x)))
    }
}

// MARK: - Convolution module

/// Pointwise-expand → GLU → depthwise(k=9) → BatchNorm(eval) → SiLU → pointwise.
/// Operates on `[B, T, C]` (channel-last, MLX `Conv1d`'s `NLC`).
nonisolated final class ParakeetConvModule: Module {
    let padding: Int
    @ModuleInfo(key: "pointwise_conv1") var pointwiseConv1: Conv1d
    @ModuleInfo(key: "depthwise_conv") var depthwiseConv: Conv1d
    @ModuleInfo(key: "batch_norm") var batchNorm: BatchNorm
    @ModuleInfo(key: "pointwise_conv2") var pointwiseConv2: Conv1d

    nonisolated init(dModel: Int, kernelSize: Int, bias: Bool) {
        precondition((kernelSize - 1) % 2 == 0, "conv kernel must be odd")
        self.padding = (kernelSize - 1) / 2
        self._pointwiseConv1.wrappedValue = Conv1d(
            inputChannels: dModel, outputChannels: dModel * 2, kernelSize: 1, bias: bias)
        self._depthwiseConv.wrappedValue = Conv1d(
            inputChannels: dModel, outputChannels: dModel, kernelSize: kernelSize,
            groups: dModel, bias: bias)
        self._batchNorm.wrappedValue = BatchNorm(featureCount: dModel)
        self._pointwiseConv2.wrappedValue = Conv1d(
            inputChannels: dModel, outputChannels: dModel, kernelSize: 1, bias: bias)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = pointwiseConv1(x)                    // [B, T, 2C]
        x = glu(x, axis: 2)                          // [B, T, C]
        // Pad the time axis only (constant 0), matching the Python's manual pad.
        x = MLX.padded(
            x, widths: [IntOrPair((0, 0)), IntOrPair((padding, padding)), IntOrPair((0, 0))])
        x = depthwiseConv(x)                         // [B, T, C]
        x = batchNorm(x)                             // eval-mode: uses running mean/var
        x = silu(x)
        return pointwiseConv2(x)                     // [B, T, C]
    }
}

// MARK: - Conformer block (macaron FF · rel-pos attn · conv · macaron FF · LN)

nonisolated final class ParakeetConformerBlock: Module {
    @ModuleInfo(key: "norm_feed_forward1") var normFeedForward1: LayerNorm
    @ModuleInfo(key: "feed_forward1") var feedForward1: ParakeetFeedForward
    @ModuleInfo(key: "norm_self_att") var normSelfAtt: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttn: ParakeetRelPosAttention
    @ModuleInfo(key: "norm_conv") var normConv: LayerNorm
    @ModuleInfo(key: "conv") var conv: ParakeetConvModule
    @ModuleInfo(key: "norm_feed_forward2") var normFeedForward2: LayerNorm
    @ModuleInfo(key: "feed_forward2") var feedForward2: ParakeetFeedForward
    @ModuleInfo(key: "norm_out") var normOut: LayerNorm

    nonisolated init(config: ParakeetConformerConfig) {
        let dModel = config.dModel
        let dFF = dModel * config.ffExpansionFactor
        self._normFeedForward1.wrappedValue = LayerNorm(dimensions: dModel)
        self._feedForward1.wrappedValue = ParakeetFeedForward(dModel: dModel, dFF: dFF, bias: config.useBias)
        self._normSelfAtt.wrappedValue = LayerNorm(dimensions: dModel)
        self._selfAttn.wrappedValue = ParakeetRelPosAttention(
            nHeads: config.nHeads, nFeat: dModel, bias: config.useBias)
        self._normConv.wrappedValue = LayerNorm(dimensions: dModel)
        self._conv.wrappedValue = ParakeetConvModule(
            dModel: dModel, kernelSize: config.convKernelSize, bias: config.useBias)
        self._normFeedForward2.wrappedValue = LayerNorm(dimensions: dModel)
        self._feedForward2.wrappedValue = ParakeetFeedForward(dModel: dModel, dFF: dFF, bias: config.useBias)
        self._normOut.wrappedValue = LayerNorm(dimensions: dModel)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, posEmb: MLXArray) -> MLXArray {
        var x = x + 0.5 * feedForward1(normFeedForward1(x))
        x = x + selfAttn(normSelfAtt(x), posEmb: posEmb)
        x = x + conv(normConv(x))
        x = x + 0.5 * feedForward2(normFeedForward2(x))
        return normOut(x)
    }
}

// MARK: - Depthwise-striding subsampling stem (factor 8 → 0.08 s/frame)

/// Mel `[B, T, featIn]` → `[B, T/8, dModel]`. Three stride-2 conv stages: a full
/// `Conv2d(1→C)` then two depthwise-separable `Conv2d` pairs, each followed by
/// ReLU; the freq axis collapses `128 → 16` and the flattened `C·16` projects to
/// `dModel`. The `conv` array keeps ReLU instances in their slots so the loaded
/// indices line up with the safetensors keys `conv.{0,2,3,5,6}` (ReLU at 1,4,7).
nonisolated final class ParakeetSubsampling: Module {
    let conv: [Module]
    @ModuleInfo(key: "out") var out: Linear

    nonisolated init(config: ParakeetConformerConfig) {
        let factor = config.subsamplingFactor
        precondition(factor > 0 && (factor & (factor - 1)) == 0, "subsampling factor must be a power of two")
        let samplingNum = Int(log2(Double(factor)))
        let channels = config.subsamplingConvChannels
        let stride = 2, kernelSize = 3, padding = 1

        var finalFreqDim = config.featIn
        for _ in 0 ..< samplingNum {
            finalFreqDim = (finalFreqDim + 2 * padding - kernelSize) / stride + 1
            precondition(finalFreqDim >= 1, "non-positive final frequency dimension")
        }

        var layers: [Module] = [
            Conv2d(
                inputChannels: 1, outputChannels: channels,
                kernelSize: IntOrPair(kernelSize), stride: IntOrPair(stride), padding: IntOrPair(padding)),
            ReLU(),
        ]
        for _ in 0 ..< (samplingNum - 1) {
            layers.append(
                Conv2d(
                    inputChannels: channels, outputChannels: channels,
                    kernelSize: IntOrPair(kernelSize), stride: IntOrPair(stride),
                    padding: IntOrPair(padding), groups: channels))  // depthwise
            layers.append(
                Conv2d(
                    inputChannels: channels, outputChannels: channels,
                    kernelSize: IntOrPair(1), stride: IntOrPair(1), padding: IntOrPair(0)))  // pointwise
            layers.append(ReLU())
        }
        self.conv = layers
        self._out.wrappedValue = Linear(channels * finalFreqDim, config.dModel)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // [B, T, F] → [B, 1, T, F] → NHWC [B, T, F, 1] for Conv2d.
        var h = x.expandedDimensions(axis: 1).transposed(axes: [0, 2, 3, 1])
        for layer in conv {
            guard let unary = layer as? UnaryLayer else { continue }
            h = unary(h)
        }
        // [B, T', F', C] → [B, C, T', F'] → [B, T', C·F'].
        h = h.transposed(axes: [0, 3, 1, 2])
        let (b, c, t, f) = (h.shape[0], h.shape[1], h.shape[2], h.shape[3])
        h = h.swappedAxes(1, 2).reshaped([b, t, c * f])
        return out(h)
    }
}

// MARK: - Conformer encoder

nonisolated final class ParakeetConformerEncoder: Module {
    @ModuleInfo(key: "pre_encode") var preEncode: ParakeetSubsampling
    let layers: [ParakeetConformerBlock]
    let dModel: Int

    nonisolated init(config: ParakeetConformerConfig) {
        precondition(config.subsampling == "dw_striding", "only dw_striding subsampling is ported")
        precondition(config.selfAttentionModel == "rel_pos", "only rel_pos attention is ported")
        self.dModel = config.dModel
        self._preEncode.wrappedValue = ParakeetSubsampling(config: config)
        self.layers = (0 ..< config.nLayers).map { _ in ParakeetConformerBlock(config: config) }
        super.init()
    }

    /// `mel`: `[B, T, featIn]`. Returns `[B, T/8, dModel]`.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = preEncode(mel)
        let posEmb = parakeetRelPositionalEncoding(seqLen: x.shape[1], dModel: dModel, dtype: x.dtype)
        for layer in layers {
            x = layer(x, posEmb: posEmb)
        }
        return x
    }

    // MARK: Load (incremental cast-and-release, §3.1)

    enum LoadError: Error { case weightsLoadFailed(any Error) }

    /// Builds the encoder and loads its bf16 weights from the full
    /// `model.safetensors`, casting tensor-by-tensor and releasing each F32
    /// source so the resident set never holds F32 + bf16 at once. Only
    /// `encoder.*` keys are kept; decoder/joint tensors are dropped (their F32 is
    /// released too). See plan.T2.md §3.1 for why this exact shape is required.
    static func load(weightsURL: URL, config: ParakeetTDTConfig) throws -> ParakeetConformerEncoder {
        let encoder = ParakeetConformerEncoder(config: config.encoder)
        var arrays: [String: MLXArray]
        do {
            arrays = try MLX.loadArrays(url: weightsURL)
        } catch {
            throw LoadError.weightsLoadFailed(error)
        }

        MLX.Memory.cacheLimit = 0  // freed F32 buffers return to the OS, not a reuse pool
        var weights: [String: MLXArray] = [:]
        let prefix = "encoder."
        // Snapshot the keys, then mutate `arrays` itself so each F32 tensor's last
        // reference drops once its bf16 is materialized (the §3.1 pitfall: a dict
        // *copy* would pin every F32 buffer and OOM).
        for key in arrays.keys.sorted() {
            guard let value = arrays.removeValue(forKey: key) else { continue }
            guard key.hasPrefix(prefix) else { continue }  // drop non-encoder F32
            let cast = value.asType(.bfloat16)
            MLX.eval(cast)
            weights[String(key.dropFirst(prefix.count))] = cast
        }

        encoder.update(parameters: ModuleParameters.unflattened(weights))
        return encoder
    }
}
