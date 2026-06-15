import OSLog
import SwiftUI

/// Settings section that drives the on-device Parakeet model lifecycle by
/// observing `ParakeetModelStore.status` (T2.5) — the real replacement for the
/// throwaway DEBUG "Delete Parakeet model" button. Mirrors `WhisperModelSection`:
///   - `.missing`     → download button (with size hint)
///   - `.downloading` → progress bar + cancel
///   - `.ready`       → "Installed" + delete
///   - `.failed`      → generic actionable message + retry
///
/// The download runs in an **unstructured** `Task` (not `.task`) so it survives
/// the Settings sheet being dismissed — the store outlives the sheet and the user
/// can reopen Settings to see live progress. Status is the single source of truth,
/// so the thrown error from `download()` is logged (full detail) and otherwise
/// discarded; the UI re-renders off the store's `.failed(reason:)`.
///
/// Parakeet's bundle is ~2.4 GB (vs Whisper's ~480 MB), so the copy differs; the
/// download/progress/delete/failure machinery is otherwise identical (the failure
/// mapping is the shared `DownloadableModelStore.userFacingMessage`).
struct ParakeetModelSection: View {
    let store: ParakeetModelStore

    /// Fired after a successful delete so the caller can re-establish the engine ↔
    /// model-presence invariant (a deleted model can no longer back a
    /// `.parakeetMLX` engine selection). Defaults to a no-op for previews.
    var onDeleted: () -> Void = {}

    @State private var showDeleteConfirmation = false

    private static let logger = Logger(
        subsystem: "alteredcraft.Relay-Notes",
        category: "ParakeetModelStore"
    )

    var body: some View {
        Section {
            content
        } header: {
            Text("On-device model (Parakeet)")
        } footer: {
            Text("Parakeet transcribes fully on-device. The model is about 2.4 GB and downloads once — delete it anytime to reclaim the space.")
        }
        .alert("Delete the Parakeet model?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll need to download it again (about 2.4 GB) to use on-device Parakeet.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .missing:
            Button("Download model (≈2.4 GB)") { startDownload() }

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
                Self.logger.error("Parakeet model download failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func delete() {
        do {
            try store.delete()
            onDeleted()
        } catch {
            Self.logger.error("Parakeet model delete failed: \(String(describing: error), privacy: .public)")
        }
    }
}
