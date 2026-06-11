import Foundation

enum TranscriptionEngine: String, Sendable, CaseIterable {
    case apple
    case whisperMLX

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperMLX: return "On-device (Whisper)"
        }
    }
}
