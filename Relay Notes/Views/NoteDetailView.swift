import SwiftData
import SwiftUI

struct NoteDetailView: View {
    @Bindable var note: Note
    /// Injected from the list; `nil` in previews → the re-transcribe control is
    /// hidden. Lets you re-run this note's saved audio through another engine.
    var reTranscriber: ReTranscriber? = nil
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
    @State private var isReTranscribing = false
    @State private var reOutcome: ReTranscriber.Outcome?
    @State private var reErrorMessage: String?
    @State private var isCleaning = false
    @State private var cleanOutcome: Cleaner.Outcome?
    @State private var cleanErrorMessage: String?
    /// When a cleaned version exists, the detail shows it by default; this flips to
    /// the raw transcript. Always raw while editing (editing operates on raw).
    @State private var showOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.createdAt.formatted(date: .complete, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let model = note.transcriptionModel {
                            Label("Transcribed with \(model)", systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !isEditingTranscript {
                            reTranscribeControl
                            cleanUpControl
                            cleanedIndicator
                            editedIndicator
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
                        item: displayedTranscript,
                        subject: Text(note.displayTitle)
                    )
                    .disabled(displayedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Share transcript")
                }
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
            Text("This will permanently delete the transcript and the audio file.")
        }
        .confirmationDialog(
            "Revert to the original transcription?",
            isPresented: $showRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) { revertTranscript() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your edits will be discarded and the original transcription restored.")
        }
        .sheet(item: $reOutcome) { outcome in
            RevisionComparisonView(
                title: "Re-transcription",
                left: .init(
                    label: "Current — \(note.transcriptionModel ?? "Unknown")",
                    text: note.transcript
                ),
                right: .init(
                    label: "New — \(outcome.modelLabel)",
                    text: outcome.transcript,
                    emphasized: true
                ),
                primary: .init(title: "Replace") {
                    note.transcript = outcome.transcript
                    note.transcriptionModel = outcome.modelLabel
                    // A re-transcription is a fresh machine baseline, so any prior
                    // hand-edit no longer applies — the note returns to pristine.
                    note.originalTranscript = nil
                    try? modelContext.save()
                    reOutcome = nil
                },
                secondary: .init(title: "Keep original") { reOutcome = nil }
            )
        }
        .alert(
            "Couldn't re-transcribe",
            isPresented: Binding(
                get: { reErrorMessage != nil },
                set: { if !$0 { reErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(reErrorMessage ?? "")
        }
        .sheet(item: $cleanOutcome) { outcome in
            RevisionComparisonView(
                title: "Clean up",
                left: .init(label: "Original", text: outcome.raw),
                right: .init(
                    label: "Cleaned — \(outcome.modelLabel)",
                    text: outcome.cleaned,
                    emphasized: true
                ),
                primary: .init(title: "Accept") {
                    note.applyCleanup(outcome.cleaned, model: outcome.modelLabel)
                    try? modelContext.save()
                    showOriginal = false
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

    /// "Re-transcribe with…" menu, shown only when a reprocessor is injected and
    /// the note's audio is still on disk. While a re-run is in flight it becomes
    /// a progress label. Re-running an engine (incl. the one that produced the
    /// note) is allowed — useful as a spot-check, not just a cross-engine A/B.
    @ViewBuilder
    private var reTranscribeControl: some View {
        if let reTranscriber, reTranscriber.audioExists(for: note) {
            if isReTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Re-transcribing…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            } else {
                Menu {
                    ForEach(reTranscriber.availableEngines, id: \.self) { engine in
                        Button(engine.displayName) {
                            runReTranscribe(reTranscriber, using: engine)
                        }
                    }
                } label: {
                    Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .padding(.top, 2)
            }
        }
    }

    private func runReTranscribe(_ reTranscriber: ReTranscriber, using engine: TranscriptionEngine) {
        isReTranscribing = true
        reErrorMessage = nil
        Task {
            defer { isReTranscribing = false }
            do {
                reOutcome = try await reTranscriber.retranscribe(note, using: engine)
            } catch {
                reErrorMessage = ReTranscriber.userMessage(for: error)
            }
        }
    }

    /// "Clean up" affordance — shown only for a not-yet-cleaned note with text and
    /// a cleaner injected. Becomes a progress label while running; when the model
    /// isn't downloaded it's a "Set up cleanup model" link that deep-links to the
    /// Tuning sheet. (A cleaned note shows `cleanedIndicator` instead.)
    @ViewBuilder
    private var cleanUpControl: some View {
        if let cleaner,
           !note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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

    /// Shown once a note has a cleaned version: provenance + a raw/cleaned toggle +
    /// a "Remove" affordance (drops the cleaned copy; the raw transcript is always
    /// preserved). Mirrors `editedIndicator`'s inline caption style.
    @ViewBuilder
    private var cleanedIndicator: some View {
        if note.isCleaned {
            VStack(alignment: .leading, spacing: 4) {
                if let model = note.cleanupModel {
                    Label("Cleaned with \(model)", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(showOriginal ? "Show cleaned" : "Show original") {
                        showOriginal.toggle()
                    }
                    Button("Remove", role: .destructive) {
                        note.clearCleanup()
                        try? modelContext.save()
                        showOriginal = false
                    }
                }
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

    /// The transcript body: read-only selectable text, or an expanding multi-line
    /// editor while in edit mode. `TextField(axis: .vertical)` (not `TextEditor`)
    /// so it grows with content and scrolls naturally inside the outer `ScrollView`.
    /// True when the cleaned version should be shown — it exists, the user hasn't
    /// toggled to raw, and we're not editing (editing always operates on raw).
    private var showingCleaned: Bool {
        note.isCleaned && !showOriginal && !isEditingTranscript
    }

    /// The text currently displayed (and shared): the cleaned version when
    /// `showingCleaned`, otherwise the canonical raw transcript.
    private var displayedTranscript: String {
        showingCleaned ? (note.cleanedTranscript ?? note.transcript) : note.transcript
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if isEditingTranscript {
            TextField("Transcript", text: $transcriptDraft, axis: .vertical)
                .font(.body)
                .focused($transcriptFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(displayedTranscript)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    /// Shown only once a note has been hand-edited: an "Edited" tag plus a
    /// revert-to-original affordance (guarded by a confirmation). Mirrors the
    /// inline caption style of `reTranscribeControl`.
    @ViewBuilder
    private var editedIndicator: some View {
        if note.isEdited {
            HStack(spacing: 10) {
                Label("Edited", systemImage: "pencil")
                Button("Revert to original") { showRevertConfirmation = true }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private func beginTranscriptEdit() {
        transcriptDraft = note.transcript
        isEditingTranscript = true
        transcriptFocused = true
    }

    private func cancelTranscriptEdit() {
        isEditingTranscript = false
        transcriptFocused = false
    }

    private func commitTranscriptEdit() {
        note.applyEditedTranscript(transcriptDraft)
        try? modelContext.save()
        isEditingTranscript = false
        transcriptFocused = false
    }

    private func revertTranscript() {
        note.revertTranscript()
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
