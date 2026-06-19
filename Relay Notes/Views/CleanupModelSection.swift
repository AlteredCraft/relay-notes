import SwiftUI

/// Settings/Tuning section driving the on-device **cleanup** (LLM) model
/// lifecycle. A thin wrapper over `ModelDownloadSection` with Gemma's copy.
///
/// Keeping cleanup-model management here (not inline at the "Clean up" action)
/// centralizes all model downloads in one place; the per-note action just gates
/// on readiness and deep-links here when the model is absent. No `onDeleted`
/// reconcile — it isn't a transcription engine, so deleting it can't invalidate
/// an engine selection.
struct CleanupModelSection: View {
    let store: CleanupModelStore

    var body: some View {
        ModelDownloadSection(
            store: store,
            header: "Cleanup model (Gemma 4 E2B)",
            footer: "Cleans up transcripts fully on-device — removes fillers, fixes punctuation, tidies wording. The model is about 3.4 GB and downloads once; delete it anytime to reclaim the space. \"Clean up\" on a note is unavailable until it's installed.",
            downloadButtonTitle: "Download model (≈3.4 GB)",
            deleteAlertTitle: "Delete the cleanup model?",
            deleteAlertMessage: "You'll need to download it again (about 3.4 GB) to clean up notes. Transcripts you've already cleaned are kept.",
            logCategory: "CleanupModelStore"
        )
    }
}
