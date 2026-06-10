#if DEBUG
import Foundation
import MLX
import MLXRandom

/// One-shot smoke for the mlx-swift runtime. Invoked from the Tuning sheet's
/// debug section in T1.1a — confirms the SPM dep links and Metal is reachable
/// from the app on the iPhone 15 Pro Max. Simulator is documented to crash on
/// MLX import (insufficient `MTLGPUFamily`), so the only useful run is on device.
/// T1.1b will repurpose this into a Whisper transcript smoke against a checked-in WAV.
nonisolated enum MLXSmoke {
    static func run() {
        let info = GPU.deviceInfo()
        print("[MLXSmoke] Metal device:")
        print("  architecture                 = \(info.architecture)")
        print("  maxBufferSize                = \(info.maxBufferSize)")
        print("  maxRecommendedWorkingSetSize = \(info.maxRecommendedWorkingSetSize)")
        print("  memorySize                   = \(info.memorySize)")

        let a = MLXRandom.normal([4, 4])
        let b = MLXRandom.normal([4, 4])
        let c = a.matmul(b).sum()
        eval(c)
        let scalar: Float = c.item()
        print("[MLXSmoke] sum(N(0,1)[4,4] @ N(0,1)[4,4]) = \(scalar)")
    }
}
#endif
