import SwiftData
import SwiftUI

/// Minimal prod note view (R1.2): shows the note's *active* revision and lets the
/// user move it forward — Clean up, manual Edit, Revert. Re-transcription and the
/// full revision history live in the `#if DEBUG` surface (R1.3), not here.
struct NoteDetailView: View {
    @Bindable var note: Note
    /// Cleanup controller; `nil` in previews → the "Clean up" control is hidden.
    var cleaner: Cleaner? = nil
    /// Deep-link to the Tuning sheet (for the "Set up cleanup model" link).
    var onOpenSettings: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var player = AudioPlayer()
    @State private var showDeleteConfirmation = false
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool
    @State private var isEditingTranscript = false
    @State private var transcriptDraft: String = ""
    @State private var showRevertConfirmation = false
    @FocusState private var transcriptFocused: Bool
    @State private var isCleaning = false
    @State private var cleanOutcome: Cleaner.Outcome?
    @State private var cleanErrorMessage: String?

    /// Whether the note's recording still exists on disk. `SampleNotes` never had
    /// one and older notes may have had it removed, so the `#if DEBUG` audio share
    /// is gated on this (sharing a missing file URL would share nothing).
    private var audioFileExists: Bool {
        FileManager.default.fileExists(atPath: note.audioURL.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.createdAt.formatted(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        provenanceLabel
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !isEditingTranscript {
                            cleanUpControl
                            revertControl
                        }
                    }
                    transcriptSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            Divider()
            playerControls
                .padding()
                .background(.regularMaterial)
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditingTranscript)
        .toolbar {
            if isEditingTranscript {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancelTranscriptEdit() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { commitTranscriptEdit() }
                        .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { beginTranscriptEdit() }
                        .accessibilityLabel("Edit transcript")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: note.displayText,
                        subject: Text(note.displayTitle)
                    )
                    .disabled(note.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Share transcript")
                }
                #if DEBUG
                // Debug-only: pull the raw recording off the device (AirDrop / Files)
                // to seed the transcription WER corpus (GH #17) with troublesome
                // real-world examples. Hidden when the note has no audio on disk.
                if audioFileExists {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: note.audioURL) {
                            Image(systemName: "waveform")
                        }
                        .accessibilityLabel("Share audio file for test corpus (debug)")
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete note")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        commitTitle()
                        titleFocused = false
                    }
                }
            }
        }
        .task {
            player.load(url: note.audioURL)
            titleDraft = note.title ?? ""
        }
        .onChange(of: titleFocused) { _, isFocused in
            if !isFocused { commitTitle() }
        }
        .onDisappear {
            commitTitle()
            player.stop()
            // Free the ~2.7 GB cleanup model when leaving the note (§3.3).
            Task { await cleaner?.evict() }
        }
        .alert("Delete this note?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                player.stop()
                note.deleteWithAudio(in: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete the note and its audio file.")
        }
        .confirmationDialog(
            "Revert to the previous version?",
            isPresented: $showRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) { revertActiveRevision() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This shows the version before this change. Your other versions are kept.")
        }
        .sheet(item: $cleanOutcome) { outcome in
            RevisionComparisonView(
                title: "Clean up",
                left: .init(label: "Current", text: outcome.raw),
                right: .init(
                    label: "Cleaned — \(outcome.modelLabel)",
                    text: outcome.cleaned,
                    emphasized: true
                ),
                primary: .init(title: "Accept") {
                    note.appendCleanup(text: outcome.cleaned, modelLabel: outcome.modelLabel)
                    try? modelContext.save()
                    cleanOutcome = nil
                },
                secondary: .init(title: "Discard") { cleanOutcome = nil }
            )
        }
        .alert(
            "Couldn't clean up",
            isPresented: Binding(
                get: { cleanErrorMessage != nil },
                set: { if !$0 { cleanErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(cleanErrorMessage ?? "")
        }
    }

    /// Provenance of what's currently shown — the active revision's kind + model.
    @ViewBuilder
    private var provenanceLabel: some View {
        let active = note.activeRevision
        switch active.kind {
        case .transcription:
            if let model = active.modelLabel {
                Label("Transcribed with \(model)", systemImage: "waveform")
            } else {
                Label("Transcribed", systemImage: "waveform")
            }
        case .edit:
            Label("Edited", systemImage: "pencil")
        case .cleanup:
            if let model = active.modelLabel {
                Label("Cleaned with \(model)", systemImage: "sparkles")
            } else {
                Label("Cleaned", systemImage: "sparkles")
            }
        }
    }

    /// "Clean up" affordance — shown when there's text to clean and the active
    /// revision isn't already a cleanup. Becomes a progress label while running;
    /// when the model isn't downloaded it's a "Set up cleanup model" deep-link.
    @ViewBuilder
    private var cleanUpControl: some View {
        if let cleaner,
           !note.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !note.isCleaned {
            if isCleaning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning up…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            } else if cleaner.isAvailable {
                Button {
                    runCleanup(cleaner)
                } label: {
                    Label("Clean up", systemImage: "sparkles")
                        .font(.caption)
                }
                .padding(.top, 2)
            } else {
                Button {
                    onOpenSettings?()
                } label: {
                    Label("Set up cleanup model", systemImage: "sparkles")
                        .font(.caption)
                }
                .padding(.top, 2)
                .disabled(onOpenSettings == nil)
            }
        }
    }

    /// "Revert" — shown when the active revision is derived from another (an edit or
    /// a cleanup), i.e. there's a previous version to step back to. Non-destructive:
    /// it moves the active pointer; the history is preserved.
    @ViewBuilder
    private var revertControl: some View {
        if note.activeRevision.derivedFromID != nil {
            Button {
                showRevertConfirmation = true
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .padding(.top, 2)
        }
    }

    private func runCleanup(_ cleaner: Cleaner) {
        isCleaning = true
        cleanErrorMessage = nil
        Task {
            defer { isCleaning = false }
            do {
                cleanOutcome = try await cleaner.clean(note)
            } catch {
                cleanErrorMessage = Cleaner.userMessage(for: error)
            }
        }
    }

    /// The note body: read-only selectable text, or an expanding multi-line editor
    /// while editing. `TextField(axis: .vertical)` (not `TextEditor`) so it grows
    /// with content and scrolls naturally inside the outer `ScrollView`.
    @ViewBuilder
    private var transcriptSection: some View {
        if isEditingTranscript {
            TextField("Transcript", text: $transcriptDraft, axis: .vertical)
                .font(.body)
                .focused($transcriptFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(note.displayText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func beginTranscriptEdit() {
        transcriptDraft = note.displayText
        isEditingTranscript = true
        transcriptFocused = true
    }

    private func cancelTranscriptEdit() {
        isEditingTranscript = false
        transcriptFocused = false
    }

    private func commitTranscriptEdit() {
        note.appendEdit(transcriptDraft)
        try? modelContext.save()
        isEditingTranscript = false
        transcriptFocused = false
    }

    private func revertActiveRevision() {
        note.revert()
        try? modelContext.save()
    }

    private var titleField: some View {
        TextField(autoTitlePlaceholder, text: $titleDraft)
            .font(.title3)
            .fontWeight(.semibold)
            .lineLimit(1)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit {
                commitTitle()
                titleFocused = false
            }
    }

    private var autoTitlePlaceholder: String {
        note.title == nil ? note.displayTitle : "Title"
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard note.title != newValue else { return }
        note.title = newValue
        try? modelContext.save()
    }

    @ViewBuilder
    private var playerControls: some View {
        if let error = player.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .disabled(player.duration <= 0)

                HStack {
                    Text(formatTime(player.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)

                    Spacer()

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .resizable()
                            .frame(width: 52, height: 52)
                            .foregroundStyle(Color.accentColor)
                    }
                    .disabled(player.duration <= 0)

                    Spacer()

                    Text(formatTime(player.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
