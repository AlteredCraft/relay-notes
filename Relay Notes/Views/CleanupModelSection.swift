import OSLog
import SwiftUI

/// Settings/Tuning section driving the on-device **cleanup** (LLM) model lifecycle
/// by observing `CleanupModelStore.status` (L2.4) — the same shape as
/// `WhisperModelSection` / `ParakeetModelSection`:
///   - `.missing`     → download button (with size hint)
///   - `.downloading` → progress bar + cancel
///   - `.ready`       → "Installed" + delete
///   - `.failed`      → generic actionable message + retry
///
/// Keeping cleanup-model management here (not inline at the "Clean up" action)
/// centralizes all model downloads in one place; the per-note action just gates on
/// readiness and deep-links here when the model is absent.
///
/// The download runs in an **unstructured** `Task` so it survives the sheet being
/// dismissed (the store outlives the sheet). Status is the single source of truth —
/// the thrown error is logged in full and otherwise discarded; the UI re-renders
/// off `.failed(reason:)` via the shared `DownloadableModelStore.userFacingMessage`.
struct CleanupModelSection: View {
    let store: CleanupModelStore

    @State private var showDeleteConfirmation = false

    private static let logger = Logger(
        subsystem: "alteredcraft.Relay-Notes",
        category: "CleanupModelStore"
    )

    var body: some View {
        Section {
            content
        } header: {
            Text("Cleanup model (Gemma 4 E2B)")
        } footer: {
            Text("Cleans up transcripts fully on-device — removes fillers, fixes punctuation, tidies wording. The model is about 3.4 GB and downloads once; delete it anytime to reclaim the space. \"Clean up\" on a note is unavailable until it's installed.")
        }
        .alert("Delete the cleanup model?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll need to download it again (about 3.4 GB) to clean up notes. Transcripts you've already cleaned are kept.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .missing:
            Button("Download model (≈3.4 GB)") { startDownload() }

        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int((progress * 100).rounded()))%")
                        .font(.subheadline)
                }
                Button("Cancel", role: .cancel) { store.cancelDownload() }
            }

        case .ready:
            HStack {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { showDeleteConfirmation = true }
            }

        case let .failed(reason):
            VStack(alignment: .leading, spacing: 10) {
                Text(DownloadableModelStore.userFacingMessage(for: reason))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { startDownload() }
            }
        }
    }

    private func startDownload() {
        Task {
            do {
                try await store.download()
            } catch {
                // Status already reflects `.failed(reason:)` for the UI; the full
                // error is for debugging only and never shown to the user.
                Self.logger.error("Cleanup model download failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func delete() {
        do {
            try store.delete()
        } catch {
            Self.logger.error("Cleanup model delete failed: \(String(describing: error), privacy: .public)")
        }
    }
}
