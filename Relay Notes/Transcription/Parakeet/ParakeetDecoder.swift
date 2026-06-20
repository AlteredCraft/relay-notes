import Foundation
import MLX
import MLXNN

/// Parakeet TDT (token-and-duration transducer) decoder + the top-level model
/// that wires encoder → prediction network → joint network → greedy decode.
/// Ports `senstella/parakeet-mlx`'s `rnnt.py` (`PredictNetwork`, `JointNetwork`,
/// `LSTM`) and `parakeet.py`'s `decode_greedy` to mlx-swift.
///
/// **Weight keys are the snake_case safetensors keys verbatim** (no remapper) —
/// `decoder.prediction.embed.weight`, `decoder.prediction.dec_rnn.lstm.{N}.{Wx,Wh,bias}`,
/// `joint.{enc,pred}.{weight,bias}`, `joint.joint_net.2.{weight,bias}`. mlx-swift's
/// `LSTM` already uses the `Wx`/`Wh`/`bias` parameter keys and the i/f/g/o gate
/// order the mlx-community checkpoint was converted with, so the per-layer LSTMs
/// load directly. The `joint_net` array keeps the activation + identity in slots
/// 0/1 so the final `Linear` lands at index 2 (`joint_net.2.*`).

// MARK: - Identity placeholder (occupies a module-array slot with no parameters)

/// A no-op `UnaryLayer` used to hold `joint_net[1]` (the Python `nn.Identity`) so
/// the trailing `Linear` keeps its safetensors index (`joint_net.2`). Its forward
/// is never invoked — the joint applies its layers explicitly.
nonisolated final class ParakeetIdentity: Module, UnaryLayer {
    func callAsFunction(_ x: MLXArray) -> MLXArray { x }
}

// MARK: - Prediction network (embed + 2-layer LSTM)

/// Wraps the per-layer `LSTM` stack. Single-step in greedy decode (batch 1,
/// seq 1), threading `(h, c)` of shape `[numLayers, 1, hidden]` between steps.
/// Mirrors the reference's `CustomLSTM`: transpose batch-first→seq-first, run
/// each layer, keep the last step's `(h, c)`.
nonisolated final class ParakeetLSTMStack: Module {
    let lstm: [LSTM]

    nonisolated init(inputSize: Int, hiddenSize: Int, numLayers: Int) {
        self.lstm = (0 ..< numLayers).map { i in
            LSTM(inputSize: i == 0 ? inputSize : hiddenSize, hiddenSize: hiddenSize, bias: true)
        }
        super.init()
    }

    func callAsFunction(
        _ input: MLXArray, hidden: (MLXArray, MLXArray)?
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        var outputs = input.transposed(axes: [1, 0, 2])  // [B, L, D] → [L, B, D]
        var nextH: [MLXArray] = []
        var nextC: [MLXArray] = []
        for i in 0 ..< lstm.count {
            let (allH, allC) = lstm[i](outputs, hidden: hidden.map { $0.0[i] }, cell: hidden.map { $0.1[i] })
            outputs = allH
            nextH.append(allH[-1])  // last step: [B, hidden]
            nextC.append(allC[-1])
        }
        outputs = outputs.transposed(axes: [1, 0, 2])  // [L, B, D] → [B, L, D]
        return (outputs, (MLX.stacked(nextH, axis: 0), MLX.stacked(nextC, axis: 0)))
    }
}

/// `prediction.{embed, dec_rnn}` container — matches the Python `PredictNetwork`'s
/// `self.prediction = {"embed": …, "dec_rnn": …}` dict so the keys nest correctly.
nonisolated final class ParakeetPrediction: Module {
    @ModuleInfo(key: "embed") var embed: Embedding
    @ModuleInfo(key: "dec_rnn") var decRNN: ParakeetLSTMStack

    nonisolated init(vocabPlusBlank: Int, predHidden: Int, numLayers: Int) {
        self._embed.wrappedValue = Embedding(embeddingCount: vocabPlusBlank, dimensions: predHidden)
        self._decRNN.wrappedValue = ParakeetLSTMStack(
            inputSize: predHidden, hiddenSize: predHidden, numLayers: numLayers)
        super.init()
    }
}

nonisolated final class ParakeetPredictNetwork: Module {
    @ModuleInfo(key: "prediction") var prediction: ParakeetPrediction
    let predHidden: Int

    nonisolated init(config: ParakeetDecoderConfig) {
        // `blank_as_pad` ⇒ the embedding has one extra row (the blank/pad index).
        let rows = config.blankAsPad ? config.vocabSize + 1 : config.vocabSize
        self.predHidden = config.prednet.predHidden
        self._prediction.wrappedValue = ParakeetPrediction(
            vocabPlusBlank: rows, predHidden: config.prednet.predHidden,
            numLayers: config.prednet.predRNNLayers)
        super.init()
    }

    /// `input` is the last emitted token `[1, 1]` (int), or `nil` at the start /
    /// after only-blank steps → a zero embedding (blank-as-pad).
    func callAsFunction(
        _ input: MLXArray?, _ hidden: (MLXArray, MLXArray)?
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        let embedded: MLXArray
        if let input {
            embedded = prediction.embed(input)
        } else {
            let batch = hidden?.0.shape[1] ?? 1
            embedded = MLXArray.zeros([batch, 1, predHidden], dtype: prediction.embed.weight.dtype)
        }
        return prediction.decRNN(embedded, hidden: hidden)
    }
}

// MARK: - Joint network (enc/pred projections → activation → final Linear)

nonisolated final class ParakeetJointNetwork: Module {
    @ModuleInfo(key: "enc") var enc: Linear
    @ModuleInfo(key: "pred") var pred: Linear
    /// `[activation, identity, final Linear]` — only index 2 carries weights
    /// (`joint_net.2.*`). The activation/identity slots preserve the index.
    ///
    /// **Named `joint_net` (snake_case) deliberately**: MLXNN derives an unwrapped
    /// array property's key from the property *name* (there's no `@ModuleInfo`
    /// override for arrays, like the encoder's `layers`/`conv`). A camelCase
    /// `jointNet` would key as `joint.jointNet.*` and silently miss the
    /// safetensors `joint.joint_net.2.*` under `update(verify: .none)` — leaving
    /// the final Linear at random init and producing real-but-wrong tokens.
    ///
    /// **Typed `[UnaryLayer]` (not `[Module]`)** so the joint can apply the
    /// trailing Linear as `joint_net[2](…)` directly — every element is a
    /// `UnaryLayer` — instead of a per-decode-step `as? Linear` cast + `fatalError`.
    /// The element type does **not** affect weight keying: MLXNN reflects the array
    /// by runtime value (`build(value:)` casts to `[Any]` and inspects each element
    /// as `Module`), so each slot still keys by index (`joint_net.0/1/2`).
    let joint_net: [UnaryLayer]

    nonisolated init(config: ParakeetJointConfig) {
        let net = config.jointnet
        let numClasses = config.numClasses + 1 + config.numExtraOutputs  // vocab + blank + durations
        self._enc.wrappedValue = Linear(net.encoderHidden, net.jointHidden)
        self._pred.wrappedValue = Linear(net.predHidden, net.jointHidden)
        precondition(net.activation.lowercased() == "relu", "only relu joint activation is ported")
        self.joint_net = [ReLU(), ParakeetIdentity(), Linear(net.jointHidden, numClasses)]
        super.init()
    }

    /// `enc`: `[1, 1, encoderHidden]` (one encoder frame); `pred`: `[1, 1, predHidden]`
    /// (one prediction step). Returns joint logits `[1, 1, 1, numClasses]`.
    func callAsFunction(_ encFrame: MLXArray, _ predOut: MLXArray) -> MLXArray {
        let e = enc(encFrame).expandedDimensions(axis: 2)   // [1, 1, 1, jointHidden]
        let p = pred(predOut).expandedDimensions(axis: 1)   // [1, 1, 1, jointHidden]
        let activated = relu(e + p)
        // `joint_net[2]` is the final `Linear` (slots 0/1 are the activation +
        // identity that preserve the safetensors index); apply it via `UnaryLayer`.
        return joint_net[2](activated)
    }
}

// MARK: - Top-level TDT model (encoder + decoder + joint + greedy decode)

nonisolated final class ParakeetTDTModel: Module {
    @ModuleInfo(key: "encoder") var encoder: ParakeetConformerEncoder
    @ModuleInfo(key: "decoder") var decoder: ParakeetPredictNetwork
    @ModuleInfo(key: "joint") var joint: ParakeetJointNetwork

    // Decode constants (non-MLX ⇒ not part of the parameter tree).
    let vocabulary: [String]
    let durations: [Int]
    let maxSymbols: Int
    /// Blank token index == vocabulary size (the `+1` row of the joint vocab head).
    let blankIndex: Int
    /// Seconds of audio per encoder frame: `subsamplingFactor · hopLength / sampleRate`
    /// (8 · 160 / 16000 = 0.08 s). Converts a decode `step` into a token timestamp
    /// for the long-audio chunk merge (T2.1e). Ports senstella's `time_ratio`.
    let timeRatio: Double

    nonisolated init(config: ParakeetTDTConfig) {
        self._encoder.wrappedValue = ParakeetConformerEncoder(config: config.encoder)
        self._decoder.wrappedValue = ParakeetPredictNetwork(config: config.decoder)
        self._joint.wrappedValue = ParakeetJointNetwork(config: config.joint)
        self.vocabulary = config.joint.vocabulary
        self.durations = config.decoding.durations
        self.maxSymbols = config.decoding.maxSymbols
        self.blankIndex = config.joint.vocabulary.count
        self.timeRatio =
            Double(config.encoder.subsamplingFactor)
            / Double(config.preprocessor.sampleRate)
            * Double(config.preprocessor.hopLength)
        super.init()
    }

    /// Full path: mel `[1, T, featIn]` → transcript text.
    func transcribe(_ mel: MLXArray) -> String {
        let features = encoder(mel)  // [1, S, dModel]
        let tokens = decodeGreedy(features)
        return parakeetDecodeTokens(tokens, vocabulary: vocabulary)
    }

    /// Long-audio path (T2.1e): step the raw PCM in `chunkDuration` windows with
    /// `overlapDuration` overlap, featurize + encode + decode each window
    /// independently, offset each window's token timestamps by the window start,
    /// and merge the overlap so shared tokens aren't dropped or duplicated. Ports
    /// `ParakeetTDT.transcribe(chunk_duration=…)` from `parakeet.py`.
    ///
    /// Parakeet's encoder is O(T²) in attention, and a multi-minute note would also
    /// grow the activation footprint past the no-entitlement ceiling — chunking
    /// bounds both. The whole-clip fast path (audio ≤ one window) matches the
    /// reference exactly, so short notes are byte-identical to ``transcribe(_:)``.
    ///
    /// - Parameters:
    ///   - audio: 1-D PCM, 16 kHz mono (e.g. `MLXArray(WhisperAudio.loadPCM(...))`).
    ///   - preprocessor: the model's mel config (sample rate / hop drive the windows).
    ///   - filters: cached mel filterbank from ``ParakeetAudio/melFilterbank(config:)``.
    ///   - chunkDuration: window length in seconds (reference default 120 s).
    ///   - overlapDuration: window overlap in seconds (reference default 15 s).
    func transcribeChunked(
        _ audio: MLXArray,
        preprocessor: ParakeetPreprocessConfig,
        filters: MLXArray,
        chunkDuration: Double = 120,
        overlapDuration: Double = 15
    ) -> String {
        let sampleRate = preprocessor.sampleRate
        let audioLength = audio.shape[0]
        let chunkSamples = Int(chunkDuration * Double(sampleRate))
        let overlapSamples = Int(overlapDuration * Double(sampleRate))
        let stride = max(1, chunkSamples - overlapSamples)

        // Fits one window → no chunking (identical to the reference's early return).
        if audioLength <= chunkSamples {
            let mel = ParakeetAudio.logMel(audio, config: preprocessor, filters: filters)
            return parakeetDecodeTokens(decodeGreedy(encoder(mel)), vocabulary: vocabulary)
        }

        var allTokens: [ParakeetToken] = []
        var start = 0
        while start < audioLength {
            let end = min(start + chunkSamples, audioLength)
            if end - start < preprocessor.hopLength { break }  // guard a zero-length mel

            let mel = ParakeetAudio.logMel(audio[start ..< end], config: preprocessor, filters: filters)
            let features = encoder(mel)
            MLX.eval(features)  // bound the lazy graph before the host-side decode loop

            let offset = Double(start) / Double(sampleRate)
            var chunkTokens = decodeGreedyAligned(features)
            for i in chunkTokens.indices { chunkTokens[i].start += offset }

            allTokens =
                allTokens.isEmpty
                ? chunkTokens
                : ParakeetChunkMerge.merge(allTokens, chunkTokens, overlapDuration: overlapDuration)

            start += stride
        }
        return allTokens.map(\.text).joined()
    }

    /// TDT greedy decode → emitted token ids. Thin wrapper over
    /// ``decodeGreedyAligned(_:)`` (the timestamps it carries are unused here);
    /// kept as the single-pass / whole-clip entry point.
    func decodeGreedy(_ features: MLXArray) -> [Int] {
        decodeGreedyAligned(features).map(\.id)
    }

    /// TDT greedy decode (single batch), **with per-token time alignment** for the
    /// long-audio chunk merge (T2.1e). Ports `decode_greedy`: per encoder frame,
    /// run the prediction net (advances only on a non-blank emission) + joint, read
    /// the **vocab head** (`argmax`, index == `blankIndex` ⇒ blank, don't emit) and
    /// the **duration head** (`argmax` over `durations` ⇒ frames to advance), with
    /// the `max_symbols` stuck-guard for duration-0 loops. Each emitted token records
    /// `start = step · timeRatio` and `duration = durations[decision] · timeRatio`
    /// (the pre-advance `step`, matching the reference).
    func decodeGreedyAligned(_ features: MLXArray) -> [ParakeetToken] {
        let length = features.shape[1]
        let vocabPlusBlank = blankIndex + 1  // vocab head width (incl. blank)

        var tokens: [ParakeetToken] = []
        var lastToken: Int? = nil
        var hidden: (MLXArray, MLXArray)? = nil
        var step = 0
        var newSymbols = 0

        while step < length {
            // Prediction net: embed last emitted token (or zero) → LSTM (carrying state).
            let predInput = lastToken.map { MLXArray([$0], [1, 1]) }
            let (predOut, newState) = decoder(predInput, hidden)

            // Joint on the current encoder frame → [1, 1, 1, numClasses].
            let jointOut = joint(features[0..., step ..< (step + 1)], predOut)
            let logits = jointOut[0, 0, 0]  // [numClasses]
            let predToken = Int(logits[0 ..< vocabPlusBlank].argMax(axis: -1).item(Int32.self))
            let decision = Int(logits[vocabPlusBlank...].argMax(axis: -1).item(Int32.self))

            if predToken != blankIndex {
                tokens.append(
                    ParakeetToken(
                        id: predToken,
                        text: parakeetDecodeTokens([predToken], vocabulary: vocabulary),
                        start: Double(step) * timeRatio,
                        duration: Double(durations[decision]) * timeRatio))
                lastToken = predToken
                hidden = newState
                if let hidden { MLX.eval(hidden.0, hidden.1) }  // bound the lazy graph across steps
            }

            let advance = durations[decision]
            step += advance
            newSymbols += 1
            if advance != 0 {
                newSymbols = 0
            } else if newSymbols >= maxSymbols {
                step += 1  // stuck-guard: force progress on a run of duration-0 steps
                newSymbols = 0
            }
        }
        return tokens
    }

    // MARK: Load (full model, incremental cast-and-release, §3.1)

    enum LoadError: Error { case weightsLoadFailed(any Error) }

    /// Builds the full TDT model and loads **all** weights (encoder + decoder +
    /// joint) from `model.safetensors`, casting each F32 tensor to bf16 and
    /// dropping its source before the next (`Memory.cacheLimit = 0`), so the
    /// resident set never holds F32 + bf16 at once (§3.1). Keys are the
    /// safetensors keys verbatim — no remapper.
    static func load(weightsURL: URL, config: ParakeetTDTConfig) throws -> ParakeetTDTModel {
        let model = ParakeetTDTModel(config: config)
        var arrays: [String: MLXArray]
        do {
            arrays = try MLX.loadArrays(url: weightsURL)
        } catch {
            throw LoadError.weightsLoadFailed(error)
        }

        MLX.Memory.cacheLimit = 0
        var weights: [String: MLXArray] = [:]
        weights.reserveCapacity(arrays.count)
        for key in arrays.keys.sorted() {
            guard let value = arrays.removeValue(forKey: key) else { continue }
            let cast = value.asType(.bfloat16)
            MLX.eval(cast)
            weights[key] = cast
        }
        // `verify: .noUnusedKeys` makes a key mismatch LOUD: it throws if any
        // safetensors weight isn't consumed by a module param (the bug class where
        // a camelCase property silently misses a snake_case key — `update`'s
        // default `.none` skips those, leaving random init + garbage output).
        do {
            try model.update(parameters: ModuleParameters.unflattened(weights), verify: .noUnusedKeys)
        } catch {
            throw LoadError.weightsLoadFailed(error)
        }
        // MLXNN Modules default to training mode; switch to eval so the encoder's
        // conv-module BatchNorm uses the loaded running_mean/var (not batch stats)
        // — the Python reference's `model.eval()`. Without this the encoder emits
        // subtly-wrong-but-normalized features and the decode is garbage.
        model.train(false)
        return model
    }
}
