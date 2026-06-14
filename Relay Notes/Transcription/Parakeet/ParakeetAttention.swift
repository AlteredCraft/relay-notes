import Foundation
import MLX
import MLXNN

/// Relative-positional multi-head attention for the FastConformer encoder, plus
/// the relative positional encoding it consumes. Ports
/// `senstella/parakeet-mlx`'s `attention.py` (`RelPositionMultiHeadAttention` +
/// `RelPositionalEncoding`) to mlx-swift, cross-checked against
/// `FluidInference/swift-parakeet-mlx`'s `Attention.swift`.
///
/// This is the one non-stock op in the encoder (Transformer-XL-style rel-pos
/// attention) and the classic port-trap. We port **only** the `rel_pos` variant
/// (this checkpoint's `self_attention_model`); the `rel_pos_local_attn` variant
/// and its hand-written Metal kernels are not needed.
///
/// `@ModuleInfo`/`@ParameterInfo` keys are the **snake_case safetensors keys**
/// (`linear_q`, `pos_bias_u`, …) so the weight dict loads straight into the tree
/// with no key remapper — the convention the Whisper port uses.

// MARK: - Relative positional encoding

/// Transformer-XL relative positional embedding for a sequence of `seqLen`
/// frames: `[1, 2·seqLen − 1, dModel]`, ordered from position `+(seqLen−1)` down
/// to `−(seqLen−1)`.
///
/// The Python keeps a full `[1, 2·maxLen−1, dModel]` buffer (maxLen 5000) and
/// slices a centered `2·seqLen−1` window out of it; that slice is identical to
/// computing the embedding directly for `seqLen`, so we skip the 9999-row buffer
/// and build exactly what's needed. `xscaling` is `false` for this checkpoint, so
/// there is no input scaling (the Python's `x * scale` with `scale = 1`).
///
/// `nonisolated` free function — no learned parameters (the embedding is
/// deterministic), so it stays out of the module tree entirely.
nonisolated func parakeetRelPositionalEncoding(seqLen: Int, dModel: Int, dtype: DType) -> MLXArray {
    precondition(dModel % 2 == 0, "dModel must be even")
    // positions: [seqLen-1, seqLen-2, …, 0, …, -(seqLen-1)] — length 2·seqLen-1.
    let positions = MLXArray(stride(from: seqLen - 1, through: -(seqLen - 1), by: -1).map(Float.init))
        .expandedDimensions(axis: 1)  // [L, 1]
    // div_term = exp(arange(0, dModel, 2) · -(ln 10000 / dModel)).
    let divTerm = MLX.exp(
        MLXArray(stride(from: 0, to: dModel, by: 2).map(Float.init))
            * (-Foundation.log(Float(10000.0)) / Float(dModel)))  // [dModel/2]
    let angles = positions * divTerm  // [L, dModel/2] (broadcast)
    // Interleave sin/cos into the channel axis: pe[:,0::2]=sin, pe[:,1::2]=cos.
    let interleaved = MLX.stacked([MLX.sin(angles), MLX.cos(angles)], axis: -1)  // [L, dModel/2, 2]
    let pe = interleaved.reshaped([positions.shape[0], dModel])  // [L, dModel]
    return pe.expandedDimensions(axis: 0).asType(dtype)  // [1, L, dModel]
}

// MARK: - Relative-position multi-head attention

/// Rel-pos MHA. `pos_bias_u`/`pos_bias_v` are **per-layer** (`untie_biases=true`),
/// shape `[nHeads, headDim]`. The encoder is `use_bias=false`, so the q/k/v/out/pos
/// projections carry no bias.
nonisolated final class ParakeetRelPosAttention: Module {
    let nHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "linear_q") var linearQ: Linear
    @ModuleInfo(key: "linear_k") var linearK: Linear
    @ModuleInfo(key: "linear_v") var linearV: Linear
    @ModuleInfo(key: "linear_out") var linearOut: Linear
    @ModuleInfo(key: "linear_pos") var linearPos: Linear
    @ParameterInfo(key: "pos_bias_u") var posBiasU: MLXArray
    @ParameterInfo(key: "pos_bias_v") var posBiasV: MLXArray

    nonisolated init(nHeads: Int, nFeat: Int, bias: Bool) {
        self.nHeads = nHeads
        self.headDim = nFeat / nHeads
        self.scale = 1.0 / Foundation.sqrt(Float(headDim))
        self._linearQ.wrappedValue = Linear(nFeat, nFeat, bias: bias)
        self._linearK.wrappedValue = Linear(nFeat, nFeat, bias: bias)
        self._linearV.wrappedValue = Linear(nFeat, nFeat, bias: bias)
        self._linearOut.wrappedValue = Linear(nFeat, nFeat, bias: bias)
        self._linearPos.wrappedValue = Linear(nFeat, nFeat, bias: false)
        self._posBiasU.wrappedValue = MLXArray.zeros([nHeads, headDim])
        self._posBiasV.wrappedValue = MLXArray.zeros([nHeads, headDim])
        super.init()
    }

    /// Shift the relative-position scores so column `j` of the output row `i`
    /// holds the score for relative offset `i − j`. (Transformer-XL `rel_shift`.)
    private func relShift(_ x: MLXArray) -> MLXArray {
        let b = x.shape[0], h = x.shape[1], tq = x.shape[2], posLen = x.shape[3]
        let padded = MLX.padded(
            x, widths: [IntOrPair((0, 0)), IntOrPair((0, 0)), IntOrPair((0, 0)), IntOrPair((1, 0))])
        return padded
            .reshaped([b, h, posLen + 1, tq])[0..., 0..., 1..., 0...]
            .reshaped([b, h, tq, posLen])
    }

    /// `x` is the pre-LN'd block input used for q, k, and v (self-attention);
    /// `posEmb` is `[1, 2·T−1, nFeat]`. No `mask` is passed for full attention.
    func callAsFunction(_ x: MLXArray, posEmb: MLXArray) -> MLXArray {
        let q = linearQ(x)
        let k = linearK(x)
        let v = linearV(x)
        let p = linearPos(posEmb)

        let batch = q.shape[0], qSeq = q.shape[1], kSeq = k.shape[1], posLen = p.shape[1]

        let qHeads = q.reshaped([batch, qSeq, nHeads, headDim])
        // (q + bias_u) and (q + bias_v) both → [B, H, Tq, headDim].
        let qU = (qHeads + posBiasU).transposed(axes: [0, 2, 1, 3])
        let qV = (qHeads + posBiasV).transposed(axes: [0, 2, 1, 3])

        let kHeads = k.reshaped([batch, kSeq, nHeads, headDim]).transposed(axes: [0, 2, 1, 3])
        let vHeads = v.reshaped([batch, kSeq, nHeads, headDim]).transposed(axes: [0, 2, 1, 3])
        let pHeads = p.reshaped([batch, posLen, nHeads, headDim]).transposed(axes: [0, 2, 1, 3])

        // matrix_bd = (q+bias_v) · pᵀ, rel-shifted and trimmed to key length, scaled.
        var matrixBD = MLX.matmul(qV, pHeads.swappedAxes(-2, -1))  // [B, H, Tq, posLen]
        matrixBD = relShift(matrixBD)[0..., 0..., 0..., 0 ..< kSeq] * scale  // [B, H, Tq, Tk]

        // SDPA computes softmax(scale·(qU·kᵀ) + matrix_bd): passing the (already
        // scaled) matrix_bd as the additive mask is the Transformer-XL AC+BD sum.
        let attended = MLXFast.scaledDotProductAttention(
            queries: qU, keys: kHeads, values: vHeads, scale: scale, mask: matrixBD)

        let merged = attended.transposed(axes: [0, 2, 1, 3]).reshaped([batch, qSeq, nHeads * headDim])
        return linearOut(merged)
    }
}
