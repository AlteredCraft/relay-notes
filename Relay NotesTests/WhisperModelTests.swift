import Foundation
import Testing
@testable import Relay_Notes

/// Config-shape tests for `WhisperModel` (T1.1b-3).
///
/// The model itself can only be instantiated on device — every weight in
/// `weights.safetensors` is an `MLXArray`, and any MLX op crashes the iOS
/// Simulator (insufficient `MTLGPUFamily`). Device-side validation runs via
/// the `MLXSmoke.run()` debug button: load time, encoder forward shape,
/// encoder forward time.
struct WhisperModelTests {

    @Test
    func configLoadsFromBundle() throws {
        let dims = try ModelDimensions.loadFromBundle()
        // Values pinned to whisper-tiny.en
        // (https://huggingface.co/mlx-community/whisper-tiny.en-mlx).
        #expect(dims.n_mels        == 80)
        #expect(dims.n_audio_ctx   == 1_500)
        #expect(dims.n_audio_state == 384)
        #expect(dims.n_audio_head  == 6)
        #expect(dims.n_audio_layer == 4)
        #expect(dims.n_vocab       == 51_864)  // English-only build
        #expect(dims.n_text_ctx    == 448)
        #expect(dims.n_text_state  == 384)
        #expect(dims.n_text_head   == 6)
        #expect(dims.n_text_layer  == 4)
    }
}
