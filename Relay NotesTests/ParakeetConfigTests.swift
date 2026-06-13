import Foundation
import Testing

@testable import Relay_Notes

/// Pure `Codable` coverage for `ParakeetTDTConfig` — simulator-safe (no MLX).
/// Pins the custom-init branches: nested `greedy.max_symbols`, the `preemph`
/// absent-vs-present-vs-null semantics, and the defaulted `numExtraOutputs` /
/// `maxSymbols`.
struct ParakeetConfigTests {

    /// A config exercising the *present* branches: explicit `greedy.max_symbols`,
    /// a `preemph` value, and an explicit `num_extra_outputs`.
    private static let fullJSON = """
    {
      "preprocessor": {
        "sample_rate": 16000, "normalize": "per_feature",
        "window_size": 0.025, "window_stride": 0.01, "window": "hann",
        "features": 128, "n_fft": 512, "dither": 1e-05,
        "pad_to": 0, "pad_value": 0.0, "preemph": 0.97
      },
      "encoder": {
        "feat_in": 128, "n_layers": 24, "d_model": 1024, "n_heads": 8,
        "ff_expansion_factor": 4, "subsampling_factor": 8,
        "self_attention_model": "rel_pos", "subsampling": "dw_striding",
        "conv_kernel_size": 9, "subsampling_conv_channels": 256,
        "pos_emb_max_len": 5000, "use_bias": false, "xscaling": false
      },
      "decoder": {
        "blank_as_pad": true, "vocab_size": 1024,
        "prednet": { "pred_hidden": 640, "pred_rnn_layers": 2 }
      },
      "joint": {
        "num_classes": 1024, "vocabulary": ["<unk>", "\\u2581the", "a"],
        "jointnet": { "joint_hidden": 640, "activation": "relu",
                      "encoder_hidden": 1024, "pred_hidden": 640 },
        "num_extra_outputs": 5
      },
      "decoding": {
        "model_type": "tdt", "durations": [0, 1, 2, 3, 4],
        "greedy": { "max_symbols": 7 }
      }
    }
    """

    /// The same config with the *absent* branches: no `greedy` block, no
    /// `preemph`, no `num_extra_outputs`.
    private static let minimalJSON = """
    {
      "preprocessor": {
        "sample_rate": 16000, "normalize": "per_feature",
        "window_size": 0.025, "window_stride": 0.01, "window": "hann",
        "features": 128, "n_fft": 512
      },
      "encoder": {
        "feat_in": 128, "n_layers": 24, "d_model": 1024, "n_heads": 8,
        "ff_expansion_factor": 4, "subsampling_factor": 8,
        "self_attention_model": "rel_pos", "subsampling": "dw_striding",
        "conv_kernel_size": 9, "subsampling_conv_channels": 256,
        "pos_emb_max_len": 5000, "use_bias": false, "xscaling": false
      },
      "decoder": {
        "blank_as_pad": true, "vocab_size": 1024,
        "prednet": { "pred_hidden": 640, "pred_rnn_layers": 2 }
      },
      "joint": {
        "num_classes": 1024, "vocabulary": ["<unk>"],
        "jointnet": { "joint_hidden": 640, "activation": "relu",
                      "encoder_hidden": 1024, "pred_hidden": 640 }
      },
      "decoding": { "model_type": "tdt", "durations": [0, 1, 2, 3, 4] }
    }
    """

    private func decode(_ json: String) throws -> ParakeetTDTConfig {
        try JSONDecoder().decode(ParakeetTDTConfig.self, from: Data(json.utf8))
    }

    @Test func decodesEncoderAndPreprocessorDims() throws {
        let c = try decode(Self.fullJSON)
        #expect(c.encoder.dModel == 1024)
        #expect(c.encoder.nLayers == 24)
        #expect(c.encoder.nHeads == 8)
        #expect(c.encoder.subsamplingFactor == 8)
        #expect(c.encoder.useBias == false)
        #expect(c.preprocessor.features == 128)
        #expect(c.preprocessor.nFFT == 512)
        #expect(c.preprocessor.normalize == "per_feature")
    }

    @Test func derivesWindowAndHopSamples() throws {
        let c = try decode(Self.fullJSON)
        // 0.025 s × 16000 = 400 samples; 0.01 s × 16000 = 160 samples.
        #expect(c.preprocessor.winLength == 400)
        #expect(c.preprocessor.hopLength == 160)
        // mag_power is a constant, not decoded.
        #expect(c.preprocessor.magPower == 2.0)
    }

    @Test func decodesPresentOptionalAndGreedyBranches() throws {
        let c = try decode(Self.fullJSON)
        #expect(c.preprocessor.preemph == 0.97)
        #expect(c.joint.numExtraOutputs == 5)
        #expect(c.decoding.maxSymbols == 7)
        #expect(c.decoding.durations == [0, 1, 2, 3, 4])
        #expect(c.decoding.modelType == "tdt")
        #expect(c.joint.vocabulary.count == 3)
    }

    @Test func appliesDefaultsWhenOptionalsAbsent() throws {
        let c = try decode(Self.minimalJSON)
        // Absent `preemph` ⇒ the NeMo/senstella dataclass default 0.97 (the model
        // was trained with it), NOT nil — see ParakeetConfig RISK 1 / plan.T2.md §5.2.
        #expect(c.preprocessor.preemph == 0.97)
        #expect(c.preprocessor.dither == nil)
        #expect(c.joint.numExtraOutputs == 0)   // default when key absent
        #expect(c.decoding.maxSymbols == 10)     // default when greedy block absent
    }

    /// An *explicit* `preemph: null` means "disabled" and must decode to `nil`,
    /// distinct from an absent key (which defaults to 0.97). This pins the
    /// `contains`-based branch that mirrors `dacite`'s absent-vs-null handling.
    @Test func explicitNullPreemphDisablesIt() throws {
        let json = """
        {
          "preprocessor": {
            "sample_rate": 16000, "normalize": "per_feature",
            "window_size": 0.025, "window_stride": 0.01, "window": "hann",
            "features": 128, "n_fft": 512, "preemph": null
          },
          "encoder": {
            "feat_in": 128, "n_layers": 24, "d_model": 1024, "n_heads": 8,
            "ff_expansion_factor": 4, "subsampling_factor": 8,
            "self_attention_model": "rel_pos", "subsampling": "dw_striding",
            "conv_kernel_size": 9, "subsampling_conv_channels": 256,
            "pos_emb_max_len": 5000, "use_bias": false, "xscaling": false
          },
          "decoder": {
            "blank_as_pad": true, "vocab_size": 1024,
            "prednet": { "pred_hidden": 640, "pred_rnn_layers": 2 }
          },
          "joint": {
            "num_classes": 1024, "vocabulary": ["<unk>"],
            "jointnet": { "joint_hidden": 640, "activation": "relu",
                          "encoder_hidden": 1024, "pred_hidden": 640 }
          },
          "decoding": { "model_type": "tdt", "durations": [0, 1, 2, 3, 4] }
        }
        """
        let c = try decode(json)
        #expect(c.preprocessor.preemph == nil)
    }
}
