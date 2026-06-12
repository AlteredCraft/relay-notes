import OSLog
import SwiftUI

/// Settings section that drives the on-device Whisper model lifecycle by
/// observing `WhisperModelStore.status`:
///   - `.missing`     → download button (with size hint)
///   - `.downloading` → progress bar + cancel
///   - `.ready`       → "Installed" + delete
///   - `.failed`      → generic actionable message + retry
///
/// The download runs in an **unstructured** `Task` (not `.task`) so it survives
/// the Settings sheet being dismissed — the store outlives the sheet and the
/// user can reopen Settings to see live progress. Status is the single source
/// of truth, so the thrown error from `download()` is logged (full detail) and
/// otherwise discarded; the UI re-renders off the store's `.failed(reason:)`.
struct WhisperModelSection: View {
    let store: WhisperModelStore

    /// Fired after a successful delete so the caller can re-establish the
    /// engine ↔ model-presence invariant (a deleted model can no longer back a
    /// `.whisperMLX` engine selection). Defaults to a no-op for previews.
    var onDeleted: () -> Void = {}

    private static let logger = Logger(
        subsystem: "alteredcraft.Relay-Notes",
        category: "WhisperModelStore"
    )

    var body: some View {
        Section {
            content
        } header: {
            Text("On-device model")
        } footer: {
            Text("Whisper transcribes fully on-device. The model is about 480 MB and downloads once — delete it anytime to reclaim the space.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .missing:
            Button("Download model (≈480 MB)") { startDownload() }

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
                Button("Delete", role: .destructive) { delete() }
            }

        case let .failed(reason):
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.failureMessage(for: reason))
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
                // Status already reflects `.failed(reason:)` for the UI; the
                // full error is for debugging only and never shown to the user.
                Self.logger.error("Whisper model download failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func delete() {
        do {
            try store.delete()
            onDeleted()
        } catch {
            Self.logger.error("Whisper model delete failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Maps an internal `FailureReason` to **generic, actionable** user copy.
    /// Deliberately drops the diagnostic detail the reason carries (HTTP status
    /// codes, missing asset names) — that stays in logs, never in the UI.
    static func failureMessage(for reason: WhisperModelStore.FailureReason) -> String {
        switch reason {
        case .network:
            return "Couldn't download the model. Check your connection and try again."
        case .server:
            return "The model isn't available right now. Please try again later."
        case .integrityCheckFailed:
            return "The download didn't complete cleanly. Please try again."
        case .diskWriteFailed:
            return "Couldn't save the model. Free up some space and try again."
        case .bundledAssetMissing:
            return "Something went wrong preparing the model. Please try again later."
        case .cancelled:
            return "Download canceled."
        }
    }
}
