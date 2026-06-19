import SwiftUI

/// Settings section driving the on-device Parakeet model lifecycle. A thin
/// wrapper over `ModelDownloadSection` with Parakeet's copy (its bundle is
/// ~2.4 GB vs Whisper's ~480 MB) and the post-delete engine-availability
/// reconcile.
struct ParakeetModelSection: View {
    let store: ParakeetModelStore

    /// Fired after a successful delete so the caller can re-establish the engine ↔
    /// model-presence invariant (a deleted model can no longer back a
    /// `.parakeetMLX` engine selection). Defaults to a no-op for previews.
    var onDeleted: () -> Void = {}

    var body: some View {
        ModelDownloadSection(
            store: store,
            header: "On-device model (Parakeet)",
            footer: "Parakeet transcribes fully on-device. The model is about 2.4 GB and downloads once — delete it anytime to reclaim the space.",
            downloadButtonTitle: "Download model (≈2.4 GB)",
            deleteAlertTitle: "Delete the Parakeet model?",
            deleteAlertMessage: "You'll need to download it again (about 2.4 GB) to use on-device Parakeet.",
            logCategory: "ParakeetModelStore",
            onDeleted: onDeleted
        )
    }
}
