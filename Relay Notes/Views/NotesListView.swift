import SwiftData
import SwiftUI

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Note.createdAt, order: .reverse) private var allNotes: [Note]

    let searchText: String

    init(searchText: String = "") {
        self.searchText = searchText
    }

    private var filteredNotes: [Note] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allNotes }
        return allNotes.filter { $0.transcript.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if allNotes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "mic",
                    description: Text("Tap the microphone to record your first voice note.")
                )
            } else if filteredNotes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredNotes) { note in
                        NavigationLink(value: note) {
                            NoteRow(note: note)
                        }
                    }
                    .onDelete(perform: deleteNotes)
                }
                .listStyle(.plain)
            }
        }
        .navigationDestination(for: Note.self) { note in
            NoteDetailView(note: note)
        }
    }

    private func deleteNotes(at offsets: IndexSet) {
        for index in offsets {
            filteredNotes[index].deleteWithAudio(in: modelContext)
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.displayTitle)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(note.transcript)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        NotesListView()
            .modelContainer(for: Note.self, inMemory: true)
    }
}
