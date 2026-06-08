#if DEBUG
import Foundation
import SwiftData

enum SampleNotes {
    private static let samples: [(daysAgo: Int, transcript: String)] = [
        (0, "Remember to pick up groceries on the way home — milk, sourdough, eggs, coffee, and some fresh fruit if it looks good."),
        (0, "Quick reminder, the dentist appointment is on Thursday at 2 PM, need to ask about the night guard fitting too."),
        (1, "Recap from the design review: we agreed to ship the new onboarding flow in two phases, the second after we get telemetry from the first."),
        (1, "Project idea — a voice-to-text app that runs entirely on-device using Apple Speech, then later adds optional cloud cleanup."),
        (2, "Call mom this weekend about the family dinner, and remember to ask her about Aunt Carol's birthday plans."),
        (3, "Book Sam recommended: Designing Data-Intensive Applications by Martin Kleppmann. Worth picking up after I finish the current one."),
        (4, "Bug in the search predicate, case sensitivity is biting us. Either lowercase both sides or switch to localizedCaseInsensitiveContains."),
        (5, "Blog post idea — compare MLX, llama.cpp, and LiteRT-LM for on-device inference on iPhone. Real numbers from real hardware."),
        (7, "Grocery list for the dinner party Saturday: ribeye, asparagus, blue cheese, sourdough, red wine, and some good olive oil."),
        (10, "Therapy homework, practice the breathing exercises before any presentation, especially the long one Thursday morning."),
        (14, "Songs I want to learn on guitar this month: Wish You Were Here, Time, and Comfortably Numb. Maybe try the Money intro too."),
        (21, "Travel idea, plan a long weekend trip to the coast in early fall when the crowds thin out. Need to book the cabin soon.")
    ]

    static func seed(into context: ModelContext) {
        let now = Date()
        for sample in samples {
            let date = Calendar.current.date(byAdding: .day, value: -sample.daysAgo, to: now) ?? now
            let note = Note(
                createdAt: date,
                audioFilename: "sample-\(UUID().uuidString).m4a",
                transcript: sample.transcript
            )
            context.insert(note)
        }
        try? context.save()
    }

    static func deleteAll(in context: ModelContext) {
        let descriptor = FetchDescriptor<Note>()
        let notes = (try? context.fetch(descriptor)) ?? []
        for note in notes {
            note.deleteWithAudio(in: context)
        }
    }
}
#endif
