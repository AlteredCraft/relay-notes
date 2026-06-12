import Foundation
import SwiftData

@Model
final class Note {
    var id: UUID
    var createdAt: Date
    var audioFilename: String
    var transcript: String
    var title: String?

    /// Human-readable provenance label of the engine/model that produced this
    /// transcript, e.g. "Apple Speech" or "Whisper (small.en)". Optional and
    /// `nil` for notes recorded before provenance capture existed (no backfill
    /// — we never stored it historically); the detail view hides the row when
    /// absent. Captured at save time from `TranscriptionSession.modelDescription`.
    var transcriptionModel: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioFilename: String,
        transcript: String,
        title: String? = nil,
        transcriptionModel: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.title = title
        self.transcriptionModel = transcriptionModel
    }
}

extension Note {
    var audioURL: URL {
        URL.documentsDirectory.appending(path: audioFilename)
    }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count <= 6 {
            return parts.joined(separator: " ")
        }
        return parts.prefix(6).joined(separator: " ") + "…"
    }

    func deleteWithAudio(in context: ModelContext) {
        try? FileManager.default.removeItem(at: audioURL)
        context.delete(self)
        try? context.save()
    }
}
