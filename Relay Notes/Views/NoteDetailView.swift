import SwiftData
import SwiftUI

struct NoteDetailView: View {
    @Bindable var note: Note

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var player = AudioPlayer()
    @State private var showDeleteConfirmation = false
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    Text(note.createdAt.formatted(date: .complete, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note.transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: note.transcript,
                    subject: Text(note.displayTitle)
                )
                .disabled(note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
