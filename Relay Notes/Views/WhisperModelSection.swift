import SwiftUI

/// Settings section driving the on-device Whisper model lifecycle. A thin
/// wrapper over `ModelDownloadSection` with Whisper's copy and the post-delete
/// engine-availability reconcile.
struct WhisperModelSection: View {
    let store: WhisperModelStore

    /// Fired after a successful delete so the caller can re-establish the
    /// engine ↔ model-presence invariant (a deleted model can no longer back a
    /// `.whisperMLX` engine selection). Defaults to a no-op for previews.
    var onDeleted: () -> Void = {}

    var body: some View {
        ModelDownloadSection(
            store: store,
            header: "On-device model",
            footer: "Whisper transcribes fully on-device. The model is about 480 MB and downloads once — delete it anytime to reclaim the space.",
            downloadButtonTitle: "Download model (≈480 MB)",
            deleteAlertTitle: "Delete the on-device model?",
            deleteAlertMessage: "You'll need to download it again (about 480 MB) to use on-device Whisper.",
            logCategory: "WhisperModelStore",
            onDeleted: onDeleted
        )
    }

    /// Generic, actionable user copy — forwards to the shared mapping (the same
    /// one every model section uses), which drops the diagnostic detail.
    static func failureMessage(for reason: DownloadableModelStore.FailureReason) -> String {
        DownloadableModelStore.userFacingMessage(for: reason)
    }
}
