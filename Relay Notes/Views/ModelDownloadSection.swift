import OSLog
import SwiftUI

/// Shared Settings/Tuning section driving any on-device model's download
/// lifecycle by observing `DownloadableModelStore.status`:
///   - `.missing`     → download button (with size hint)
///   - `.downloading` → progress bar + cancel
///   - `.ready`       → "Installed" + delete
///   - `.failed`      → generic actionable message + retry
///
/// The Whisper / Parakeet / cleanup sections are identical except for copy and
/// the post-delete reconcile, so they're thin wrappers over this view; only the
/// strings and the `onDeleted` hook differ.
///
/// The download runs in an **unstructured** `Task` (not `.task`) so it survives
/// the sheet being dismissed — the store outlives the sheet and the user can
/// reopen it to see live progress. Status is the single source of truth, so the
/// thrown error from `download()` is logged in full and otherwise discarded; the
/// UI re-renders off the store's `.failed(reason:)` via the shared
/// `DownloadableModelStore.userFacingMessage`.
struct ModelDownloadSection: View {
    let store: DownloadableModelStore
    let header: String
    let footer: String
    let downloadButtonTitle: String
    let deleteAlertTitle: String
    let deleteAlertMessage: String

    /// `os.Logger` category, also used as the human-readable prefix in log lines.
    let logCategory: String

    /// Fired after a successful delete so the caller can re-establish any
    /// invariant the delete breaks (e.g. a deleted model can no longer back its
    /// engine selection). Defaults to a no-op for previews and callers with
    /// nothing to reconcile.
    var onDeleted: () -> Void = {}

    @State private var showDeleteConfirmation = false

    var body: some View {
        Section {
            content
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
        .alert(deleteAlertTitle, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteAlertMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .missing:
            Button(downloadButtonTitle) { startDownload() }

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

    private var logger: Logger {
        Logger(subsystem: "alteredcraft.Relay-Notes", category: logCategory)
    }

    private func startDownload() {
        Task {
            do {
                try await store.download()
            } catch {
                // Status already reflects `.failed(reason:)` for the UI; the full
                // error is for debugging only and never shown to the user.
                logger.error("\(logCategory) download failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func delete() {
        do {
            try store.delete()
            onDeleted()
        } catch {
            logger.error("\(logCategory) delete failed: \(String(describing: error), privacy: .public)")
        }
    }
}
